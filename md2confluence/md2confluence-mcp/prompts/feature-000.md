# Fix: read the Confluence token from `pass`, render Mermaid locally instead of via kroki.io

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
- At the same point `CONFLUENCE_TOKEN` is currently read in `src/index.ts`: if
  `CONFLUENCE_TOKEN` is not already set in the environment, and `pass` is
  available on `$PATH`, shell out to `pass show <entry>` (first line of output
  only, trimmed) to populate the token instead of immediately erroring out.
- Keep `CONFLUENCE_TOKEN` as a supported override — if it's already set in the
  environment, use it directly and skip `pass` entirely (keeps this working
  for CI / non-interactive use, and doesn't break existing setups).
- If neither `CONFLUENCE_TOKEN` nor `pass` (nor a working `pass` entry) is
  available, keep the existing startup error, but update its text to document
  `pass` as the primary/recommended option and the env var as the fallback.
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

## Do not make other changes.

Leave the Confluence upload/storage-format-conversion logic, the tool list,
and everything else as-is.
