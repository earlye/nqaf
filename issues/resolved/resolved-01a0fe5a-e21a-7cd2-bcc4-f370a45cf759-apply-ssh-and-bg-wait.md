# scripts: push over SSH, and don't let `claude -p` kill background work

## Context

The first `scripts/apply turso …` run (2026-09-29) hit two problems.

- **Push failed.** Every `fork.txt` held an `https://github.com/...` URL.
  This machine has no HTTPS credential helper, and `gh` is set to use SSH.
  So the first push from a fresh `work/` clone failed with
  `fatal: could not read Username for 'https://github.com'`.
- **The agent's work was cut off.** `apply` runs `claude -p`. Following
  the user's global CLAUDE.md, the agent handed the implementation to a
  background agent. `claude -p` kills background tasks after 600s
  ("Background tasks still running after 600s; terminating"), so `apply`
  committed, pushed and marked as done a fix that was only half written
  and didn't compile (earlye-forks/turso `3137b4416`). The rerun with
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` completed it.

## Fix

- Every `fork.txt` now holds an SSH URL. `apply` and `re-apply` reset an
  existing `work/` clone's `origin` to `fork.txt`, so older clones switch
  over too.
- `mirror` parses the owner from either URL form. `apply` passes
  `OWNER/REPO` to `gh repo set-default`.
- `apply` and `re-apply` export `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`.
