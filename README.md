# nqaf — "not-quite-a-fork"

This repo tracks security/correctness fixes for third-party projects as a set
of **prompts**, not as a diverging git history. Instead of maintaining a fork
with hand-merged patches, each fixed issue is written up as a self-contained
prompt that re-implements the fix from scratch against a fresh mirror of
upstream. That makes pulling in new upstream releases a matter of re-running
the prompts, not resolving merge conflicts against old patches.

## Layout

Each top-level directory (e.g. `obscura/`, `postgresparser/`,
`md2confluence/md2confluence-mcp/`) is one tracked fork, containing:

- `upstream.txt` — the URL of the upstream repo being tracked.
- `fork.txt` — the URL of *our* fork remote (what the scripts push to/pull
  from).
- `prompts/feature-NNN.md` — numbered, self-contained fix prompts, applied in
  filename order.
- `{docs}.md` (where present) — the background research/rationale
  behind that fork's prompts; not required for the scripts to work, just the
  paper trail for why each prompt exists.
- `work/` — created by the scripts below, gitignored. A local clone of the
  fork remote where prompts actually get applied. Safe to delete and
  re-clone at any time; nothing you can't reproduce lives here.

## Scripts, and what order to run them in

All three scripts live in `scripts/` and take a fork directory as their first
positional argument (e.g. `scripts/apply obscura`). They run a coding agent
**locally** (`--engine claude` (default) or `--engine oneclaw`) — there is no
cloud-hosted agent wired into this workflow, so none of this runs in CI. It's
a manual, human-triggered maintenance step: run it yourself when you want to
set up or refresh a fork.

1. **`scripts/mirror <fork-dir>`** — one-time setup for a brand-new fork.
   Does a `git clone --mirror` of upstream and `push --mirror`s it straight
   to the fork remote, so the fork starts as an exact copy of upstream before
   any prompts exist or have been applied. Only re-run this if you want to
   hard-reset the fork remote back to a raw upstream mirror (destructive —
   it overwrites the fork remote's history).

2. **`scripts/apply [--engine claude|oneclaw] <fork-dir> <branch> [prompts/feature-NNN.md ...]`**
   — clones the fork remote into `<fork-dir>/work` if needed, then checks out
   `<branch>` (creating it from the fork's default branch if it doesn't exist
   yet on origin, or checking out its current tip as-is if it does — this
   never resets or rebases the branch, so re-running `apply` on the same
   branch picks up right where it left off). Applies prompts in filename
   order (all of `prompts/*.md` by default, or just the specific ones you
   list) by running the coding agent against that working copy, one prompt
   at a time. Each prompt first has the agent check whether the fix is
   already present in the code (it may have been applied in an earlier run
   or merged in from upstream) before deciding whether to actually change
   anything; either way, the prompt gets recorded in `.nqaf/prompts/` in the
   fork so future runs on this branch can skip it. After each prompt,
   **any resulting changes are committed and pushed to `<branch>` on
   origin immediately** — so progress survives even if a later prompt in
   the same run fails. Once at least one prompt has run, it uses `gh` to
   open a PR from `<branch>` into the fork's default branch (skipped if a
   PR already exists for that branch, or if `gh` isn't installed/authed).
   Use this:
   - the first time you apply prompts to a fork, on a new branch, or
   - to apply newly-added prompts on an existing, already-pushed branch
     without redoing already-applied ones (they're skipped via
     `.nqaf/prompts/`).

3. **`scripts/re-apply [--engine claude|oneclaw] <fork-dir> [prompts/feature-NNN.md ...]`**
   — for pulling in new upstream commits without losing already-applied
   fixes. Checks whether `upstream/HEAD` has moved past `origin/HEAD`; if
   not, it's a no-op. If upstream has moved, it first tries a plain
   `git merge` of `upstream/HEAD` into `origin/HEAD` and runs `make test`.
   If that merge and the tests both succeed, you're done — the fixes still
   apply cleanly on top of the new upstream commits. If the merge conflicts,
   or it merges but tests fail, it falls back to resetting `work/` straight
   to `upstream/HEAD` and re-running every prompt from scratch against the
   new upstream base — same idea as `apply`, just starting from the new
   upstream instead of the old fork history. Run this periodically (whenever
   you know upstream has new commits you want).

**`apply` commits and pushes after every prompt, and opens a PR via `gh`.**
`mirror` and `re-apply` do not — they always leave `<fork-dir>/work` as a
dirty working tree for you to review, commit, and push yourself. `gh` needs
to be installed and authenticated against the fork's GitHub repo for PR
creation to happen; if it isn't, `apply` still does the commit/push part and
just skips opening a PR.

## Quick reference

| Situation | Run |
|---|---|
| Setting up a brand-new fork for the first time | `scripts/mirror <dir>` then `scripts/apply <dir> <branch>` |
| Adding a newly-written prompt to an already-applied branch | `scripts/apply <dir> <branch> prompts/feature-NNN.md` |
| Upstream has new commits you want to pick up | `scripts/re-apply <dir>` |
