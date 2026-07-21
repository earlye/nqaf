# [feature-000.md]
# Feature: add an automated test harness

## Problem

This repo has no test framework and no `test` script — `package.json`
(`scripts`) only has `build`, `start`, `dev`, `prepublishOnly`. A later prompt
(`feature-001.md`) needs to add real integration tests, so the harness needs
to exist first.

## Fix

Use Node's built-in test runner (`node:test`) — no new dependencies. Node 18+
is already the `engines` minimum in `package.json`.

- Add a `"test"` script to `package.json`: `"test": "npm run build && node --test dist"`.
  `node --test` given a directory recursively discovers compiled `*.test.js`
  files under it, so no glob is needed.
- Test files live at `src/**/*.test.ts`, next to the code they test. Do not
  create a separate `tsconfig.test.json` — the existing `tsconfig.json`
  already includes `src/**/*`, so `.test.ts` files compile into `dist/`
  alongside application code automatically.
- `.npmignore` currently excludes `src/`, `tsconfig.json`, and `.gitignore`
  from what gets published to npm, but nothing excludes compiled test output
  from `dist/`. Add `dist/**/*.test.js` and `dist/**/*.test.d.ts` to
  `.npmignore` so test files never ship in the published package.
- Add exactly one smoke test to prove the harness works end-to-end (build →
  discovery → run → npmignore exclusion): a new `src/converter.test.ts` that
  imports `extractTitle` and/or `removeFrontMatter` from `./converter.js`
  (both already exported, both pure, no I/O) and asserts on a couple of known
  inputs/outputs.

## Do not make other changes

Do not touch `CONFLUENCE_TOKEN`/`pass` handling, Mermaid rendering, or the
README's Installation section — those are `feature-001.md`. This prompt only
wires up the test harness and proves it runs.
