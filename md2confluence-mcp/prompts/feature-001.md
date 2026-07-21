# [feature-001.md]
# Fix: read the Confluence token from `pass`, render Mermaid locally instead of via kroki.io

This prompt depends on `feature-000.md` (test harness) having already run —
it assumes a `"test"` script exists (`node --test` over compiled `dist/`) and
that `src/**/*.test.ts` is the established location/convention for tests.

## Problem 1 — credential handling

`src/index.ts` (lines 16-26) reads `CONFLUENCE_TOKEN` (and `CONFLUENCE_URL`/`CONFLUENCE_EMAIL`)
directly from `process.env`. That means every consumer has to export the raw
Atlassian API token as a plaintext environment variable in their MCP server
config (e.g. `~/.claude/settings.json` or a project's `.mcp.json`), leaving a
live credential sitting in a config file on disk.

## Fix 1

Retrieve `CONFLUENCE_TOKEN` from the user's `pass` password store
(https://www.passwordstore.org/) instead of requiring it as a plaintext env var.

- Add an optional `CONFLUENCE_TOKEN_PASS_ENTRY` env var (default:
  `confluence/api-token`) naming the `pass` entry to read.
- Extract the token-resolution logic into a new `src/config.ts`, exporting
  `export async function resolveConfluenceToken(env: NodeJS.ProcessEnv = process.env): Promise<string>`.
  Keeping this out of `index.ts` (the server entrypoint, which starts the
  stdio transport on import) is what lets it be unit-tested directly without
  booting the whole MCP server.
- `resolveConfluenceToken`:
  - If `env.CONFLUENCE_TOKEN` is already set, return it directly — do not
    shell out to `pass` at all. This keeps CI / non-interactive setups
    working and is a supported override.
  - Otherwise, if `pass` is available on `$PATH`, run `pass show <entry>`
    (`<entry>` = `env.CONFLUENCE_TOKEN_PASS_ENTRY`, default
    `confluence/api-token`), take the first line of stdout, trimmed, and
    return it.
  - Use `child_process.execFile` (via `util.promisify`) with the command and
    args passed as an array — `execFile('pass', ['show', entry])` — never a
    shell string/`exec`, even though `entry` isn't attacker-facing.
  - If neither path yields a token (env var unset, `pass` missing from
    `$PATH`, or `pass show` exits non-zero because the entry doesn't exist),
    return `""` and let the existing `validateConfig()` in `index.ts` produce
    its startup error.
- In `index.ts`, replace the top-level `const CONFLUENCE_TOKEN = process.env.CONFLUENCE_TOKEN || ""`
  with a top-level `await resolveConfluenceToken()` call (this file is
  `"type": "module"`, so top-level `await` is valid — don't reach for
  `execFileSync`/blocking calls here).
- Update `validateConfig()`'s error text to document `pass` as the
  primary/recommended option and the env var as the fallback.
- Update the README's "Get API Token" / env var docs to describe the `pass`
  workflow (`pass insert confluence/api-token`) as the recommended setup path.

## Problem 2 — Mermaid rendering depends on a third-party network service

`src/converter.ts`'s `renderMermaidToPng` (~lines 21-34) sends the raw Mermaid
diagram source to `https://kroki.io/mermaid/png`, a public third-party
rendering service. Every diagram in every synced doc leaves the network to get
rendered, and rendering breaks entirely if kroki.io is unreachable or the
diagram shouldn't leave the machine.

## Fix 2

Replace the kroki.io call with a local render via `@mermaid-js/mermaid-cli`
(`mmdc`), invoked through `npx` so no separate install step is required.

- Replace `renderMermaidToPng`'s body: write `code` to a temp `.mmd` file in
  the OS temp dir, run
  `npx -y -p @mermaid-js/mermaid-cli mmdc -i <tmpfile>.mmd -o <tmpfile>.png -b white`,
  read back the resulting PNG bytes into a `Buffer`, then delete both temp
  files (success or failure).
- `npx` will fetch `@mermaid-js/mermaid-cli` on demand; note in the README
  that the first render downloads a headless Chromium and may take a while.
- Remove the kroki.io fetch call and the "via kroki.io" references in
  comments/README (top-of-file comment in `converter.ts`, README feature list,
  "How It Works" diagram/steps).
- Known gotcha worth a code comment: Mermaid's own parser mishandles a literal
  `#` immediately followed by digits inside note/label text (e.g. `#29380` in
  `Note over X: ...`) — doesn't need a fix here, but if you touch any
  label-escaping logic, be aware of it and don't "helpfully" strip/escape `#`
  in a way that changes unrelated diagrams.

## Problem 3 — README Installation section documents the wrong (unpatched) install path

The README's "Installation" section (both the "Claude Code" and
"Project-specific" snippets) tells readers to run
`"command": "npx", "args": ["-y", "md2confluence-mcp"]` — the published
upstream npm package. A reader following this fork's README would never
actually run Fix 1/Fix 2 above; they'd silently get the unpatched, published
version instead.

## Fix 3

Rewrite the Installation section to document building and running this fork
from source instead of `npx`-ing the published package:

- `git clone <this fork> && cd md2confluence-mcp && npm install && npm run build`
- Then point the MCP config's `confluence` server at the built output directly:
  ```json
  {
    "mcpServers": {
      "confluence": {
        "command": "node",
        "args": ["/absolute/path/to/md2confluence-mcp/dist/index.js"],
        "env": {
          "CONFLUENCE_URL": "https://your-domain.atlassian.net/wiki",
          "CONFLUENCE_EMAIL": "your@email.com"
        }
      }
    }
  }
  ```
  (note `CONFLUENCE_TOKEN` is intentionally omitted from the example now that
  Fix 1 supports reading it from `pass`).
- Apply this to both the "Claude Code" and "Project-specific" snippets.
- This prompt only rewrites the fork's own README to describe how to build
  and install *this* fork correctly — it does not modify any MCP config on
  the machine the prompt happens to run on.

## Integration tests

Building on the `node:test` harness from `feature-000.md`, add:

- `src/config.test.ts` covering `resolveConfluenceToken`:
  - **Fixture setup/teardown**: before the test, create a throwaway `pass`
    entry via `pass insert -m -f <test-entry>` (piping a known dummy value on
    stdin so it's non-interactive), pointing at a test-only path (not
    `confluence/api-token`); after the test, `pass rm -f <test-entry>`. Do not
    depend on any pre-existing entry in the developer's real password store.
  - Assert that calling `resolveConfluenceToken({ CONFLUENCE_TOKEN_PASS_ENTRY: <test-entry> })`
    (with `CONFLUENCE_TOKEN` absent from the passed env) returns exactly the
    dummy value.
  - Assert the override path: when `CONFLUENCE_TOKEN` is present in the
    passed env, `resolveConfluenceToken` returns it as-is (use a
    `CONFLUENCE_TOKEN_PASS_ENTRY` that doesn't exist, to prove `pass` is never
    consulted in this path).
- A new mermaid-rendering test (e.g. in `src/converter.test.ts`) covering
  Fix 2: call the exported `convertMarkdownToConfluence` with a markdown
  string containing a fenced ` ```mermaid ` block, assert the returned
  `attachments` array has exactly one entry, and assert its `.data` buffer's
  first 8 bytes match the PNG magic number (`89 50 4E 47 0D 0A 1A 0A`). This
  test invokes the real `npx ... mmdc` — on a machine without
  `@mermaid-js/mermaid-cli` cached, the first run downloads a headless
  Chromium and can take minutes. Give this specific test a generous timeout
  (e.g. pass `{ timeout: 120_000 }` to `node:test`'s `test()`) rather than
  relying on the runner's default.

## Do not make other changes.

Leave the Confluence upload/storage-format-conversion logic, the tool list,
and everything else as-is.
