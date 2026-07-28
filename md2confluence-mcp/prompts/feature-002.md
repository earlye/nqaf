# Fix: read CONFLUENCE_URL/CONFLUENCE_EMAIL from `pass`, add a one-time setup wizard that also registers the server with Claude Code

This prompt depends on `feature-001.md` having already run — it assumes
`src/config.ts` exports `resolveConfluenceToken` following the
env-override-then-`pass` pattern, and that `src/config.test.ts` already has
`pass insert -m -f` / `pass rm -f` fixture setup/teardown for a throwaway
test entry.

## Problem 1 — CONFLUENCE_URL/CONFLUENCE_EMAIL are still plaintext-only

`src/index.ts` reads `CONFLUENCE_URL` and `CONFLUENCE_EMAIL` directly off
`process.env` (`const CONFLUENCE_URL = process.env.CONFLUENCE_URL || ""` and
the equivalent for email), while `CONFLUENCE_TOKEN` already goes through
`resolveConfluenceToken()`'s `pass`-backed resolution from `feature-001.md`.
That's inconsistent, and it means the URL and email still have to sit in
plaintext in the MCP server config's `env` block even though the token
doesn't.

## Fix 1

Add `resolveConfluenceUrl` and `resolveConfluenceEmail` to `src/config.ts`,
following the exact same shape as `resolveConfluenceToken`:

- `export async function resolveConfluenceUrl(env: NodeJS.ProcessEnv = process.env): Promise<string>`
  — if `env.CONFLUENCE_URL` is set, return it directly (no shell-out).
  Otherwise read the `pass` entry named by `env.CONFLUENCE_URL_PASS_ENTRY`
  (default `confluence/url`) via `execFile("pass", ["show", entry])`, first
  line trimmed. Missing env var, missing `pass` on `$PATH`, or a non-zero
  `pass show` all resolve to `""`.
- `export async function resolveConfluenceEmail(env: NodeJS.ProcessEnv = process.env): Promise<string>`
  — identical shape, default pass entry `confluence/email`, override var
  `CONFLUENCE_EMAIL_PASS_ENTRY`.
- Factor the shared "env override, else `pass show <entry>`, else `\"\"`"
  logic out of all three resolvers (token/url/email) into one small private
  helper in `config.ts` (e.g. `resolveFromPassOrEnv(envVar, passEntryVar,
  defaultPassEntry, env)`) rather than copy-pasting the try/catch three
  times.
- In `src/index.ts`, replace the top-level
  `const CONFLUENCE_URL = process.env.CONFLUENCE_URL || ""` and the email
  equivalent with `await resolveConfluenceUrl()` / `await
  resolveConfluenceEmail()`, same as `CONFLUENCE_TOKEN` already does.
- Update `validateConfig()`'s error text so all three variables document the
  same shape: `pass` entry name (with its default and override env var) as
  the primary path, plaintext env var as the fallback.

## Problem 2 — no guided way to populate `pass` the first time

Once Fix 1 lands, a brand-new user has no plaintext env vars to fall back on
and probably hasn't manually run three separate `pass insert` commands
either. There's currently no walkthrough — they'd just hit the
`validateConfig()` error with no help actually resolving it.

## Design constraint this fix has to respect

The natural-sounding version of "walk the user through it" — detect missing
config inside `main()` and prompt interactively over stdin/stdout before
starting the server — **does not work here**. `StdioServerTransport` claims
stdin/stdout as the MCP JSON-RPC channel the moment the server connects;
those streams are not free to repurpose as a human terminal prompt, and by
the time `main()` runs, the MCP client (Claude Code, etc.) already launched
this process expecting protocol frames on that channel, not a prompt. So the
wizard cannot live inside `index.ts`/`main()`.

## Fix 2

Add a **separate CLI entry point** for setup, invoked manually by the user
in a real terminal — not auto-triggered by the MCP server:

- New `src/setup.ts`, compiled to `dist/setup.js`. Add a second `bin` entry
  in `package.json`: `"md2confluence-mcp-setup": "dist/setup.js"`, and a
  `"setup": "npm run build && node dist/setup.js"` script.
- Behavior:
  1. Check `pass` is on `$PATH` (e.g. `execFile("which", ["pass"])` or catch
     the ENOENT from running it). If missing, print install/init
     instructions (https://www.passwordstore.org/, `pass init <gpg-id>`) and
     exit non-zero.
  2. For each of `confluence/url`, `confluence/email`, `confluence/api-token`,
     check whether the entry already exists (`pass show <entry>` exits 0).
  3. If all three already exist, print a short "already configured" message
     and exit 0 — do not prompt, do not overwrite. This is what makes it
     safe to re-run; it's a one-time setup, not a reset command.
  4. Otherwise, using `node:readline/promises`, prompt only for the entries
     that are missing: Confluence base URL (e.g.
     `https://your-domain.atlassian.net/wiki`), Atlassian account email, and
     API token (mention https://id.atlassian.com/manage-profile/security/api-tokens
     for generating one). Note in a comment that the token prompt is not
     masked — `readline` has no built-in echo suppression, and adding a
     dependency or raw-mode TTY hack for this is out of scope here.
  5. For each newly-provided value, write it with
     `execFile("pass", ["insert", "-m", "-f", entry])`, piping the value to
     stdin (same call shape already used in `config.test.ts`'s fixture
     setup) — never build a shell string.
  6. Print a final summary of which entries were created vs. already
     present.
  7. Register this server with Claude Code (see Problem 3/Fix 3 below) —
     this step always runs, even when step 3 skipped the `pass` prompts
     because all three entries already existed. Registration has no
     interactive prompt of its own, so there's no reason to gate it behind
     "first run only."
- In `index.ts`'s `validateConfig()`, when any of the three resolved values
  is empty, add a line pointing the user at `npm run setup` (or
  `node dist/setup.js` if installed as a dependency) as the guided fix,
  alongside the existing manual `pass insert`/env var instructions.
- README: document `npm run setup` as the recommended first-run step (before
  the existing manual "Get API Token" section), and add
  `CONFLUENCE_URL_PASS_ENTRY` / `CONFLUENCE_EMAIL_PASS_ENTRY` rows to the
  Environment Variables table next to the existing
  `CONFLUENCE_TOKEN_PASS_ENTRY` row. Drop `CONFLUENCE_URL`/`CONFLUENCE_EMAIL`
  from the Installation section's example `env` blocks now that `pass` is
  the recommended path for all three credentials (keep documenting the
  plaintext env vars as a supported fallback in the table, just not in the
  "recommended" example).

## Problem 3 — registering this server with Claude Code is still a manual, hand-edited step

Even once `pass` is populated, getting Claude Code to actually launch this
server means hand-editing a config file and typing an absolute path to
`dist/index.js` (see README "Installation"). There's no command that
registers it for you.

## Fix 3

Have `setup.ts` (step 7 above) register the server **globally** (available
in every project, not just one repo checkout) using Claude Code's own CLI —
`claude mcp add` — rather than hand-editing any Claude Code config file
directly:

- Check `claude` is on `$PATH` the same way step 1 checks for `pass`
  (`execFile("which", ["claude"])` or catch ENOENT). If missing, print a
  one-line note that MCP registration was skipped and exit that step
  successfully anyway — this machine may not have Claude Code's CLI
  installed at all, and that shouldn't fail the `pass` setup that already
  ran.
- Run:
  ```
  claude mcp add confluence --scope user -- npm --prefix <repoRoot> run start
  ```
  via `execFile`, args passed as an array (never a shell string), where
  `repoRoot = process.cwd()` (this script is always invoked from the
  package root via `npm run setup`). `--scope user` is what makes this
  global — Claude Code exposes it in every project's sessions, not just
  this repo's. Using `npm --prefix <repoRoot> run start` as the command
  (rather than `node <repoRoot>/dist/index.js` directly) means Claude Code
  launches it via the same `"start": "node dist/index.js"` script already
  in `package.json`, and it needs no `env` block — `pass` resolution
  already covers all three credentials.
- **Verify by reading back, don't trust the command's stdout.** In one
  sandboxed test run, `claude mcp add` printed
  `Added stdio MCP server ... File modified: ~/.claude.json` and still
  exited non-zero because the write was rejected by the sandbox — the
  server was never actually registered (confirmed via `claude mcp get`
  afterward). So after running `add`, shell out to `claude mcp get confluence`
  and only report success if that lookup actually finds the entry; if `add`
  exits non-zero, or `get` doesn't find it afterward, print a one-line
  warning (recommend running `claude mcp add confluence --scope user --
  npm --prefix <repoRoot> run start` manually) rather than silently
  claiming success.
- This step is idempotent by construction — `claude mcp add` overwrites an
  existing entry of the same name rather than erroring or duplicating it, so
  re-running `npm run setup` (or step 7 alone) any number of times converges
  on the same registration.
- README: replace the manual `~/.claude/settings.json`/project-`.mcp.json`
  JSON-editing instructions in "Installation" with "run `npm run setup`,
  which registers this server with Claude Code globally (`claude mcp add
  ... --scope user`)." Keep one manual snippet below it as a fallback for
  anyone without the `claude` CLI on `$PATH`, or who wants project- or
  local-scoped registration instead of global.

## Do not make other changes

Leave `confluence.ts`, `converter.ts`, the tool list, and Mermaid rendering
untouched. Don't change `resolveConfluenceToken`'s exported signature beyond
factoring out the shared helper. Don't remove the plaintext env var fallback
for any of the three variables — it's still the documented, supported path
for CI/non-interactive setups. Don't hand-parse or hand-write any Claude
Code config file (`~/.claude.json` or otherwise) directly — always go
through the `claude mcp` CLI, since that file's internal shape is not a
documented, stable public format.

## Integration tests

- Extend `src/config.test.ts` with the same fixture pattern already used for
  the token (throwaway `pass insert -m -f <test-entry>` before, `pass rm -f`
  after — never touch the real `confluence/url`, `confluence/email`, or
  `confluence/api-token` entries in a test):
  - `resolveConfluenceUrl` reads from `pass` when `CONFLUENCE_URL` is unset
    in the passed env, using a `CONFLUENCE_URL_PASS_ENTRY` pointed at a
    throwaway test entry.
  - `resolveConfluenceUrl` returns the env var override without consulting
    `pass` (point `CONFLUENCE_URL_PASS_ENTRY` at a nonexistent entry to
    prove it).
  - Same two tests for `resolveConfluenceEmail`.
- Do not add an automated test that drives `setup.ts`'s interactive
  readline prompts, mutates the real default `pass` entries, or calls the
  real `claude mcp add`/registers against the real global Claude Code
  config — that's exactly the human-in-the-loop, machine-specific path
  Fix 2/Fix 3 exist for. It's fine to leave `setup.ts` untested by
  `node:test`; a manual smoke run is enough.
