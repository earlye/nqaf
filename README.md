# nqaf — "not-quite-a-fork"

This repo tracks security/correctness fixes for third-party projects as a set
of **prompts**, plus the **patch** each prompt last produced. Each fixed issue
is written up as a self-contained prompt. When upstream moves, the stored
patches are carried forward onto the new upstream; a coding agent is called
only where a patch no longer applies cleanly or its prompt has changed, and
it re-implements from the prompt only when repairing the old patch isn't
viable. The prompt stays the source of truth for *what* the fix is; the patch
is the record of *how* it was last done.

## Layout

Each top-level directory (e.g. `obscura/`, `postgresparser/`,
`md2confluence-mcp/`) is one tracked fork, containing:

- `upstream.txt` — the URL of the upstream repo being tracked.
- `fork.txt` — the URL of *our* fork remote (what the scripts push to/pull
  from).
- `prompts/feature-NNN.md` — numbered, self-contained fix prompts, applied in
  filename order.
- `patches/feature-NNN.patch` and `patches/feature-NNN.base` — written by the
  scripts, committed to this repo. The `.patch` is `git format-patch` output
  of the one commit that implemented that prompt in the fork. The `.base` is
  `key=value` lines: `parent=` (the commit the patch was applied on),
  `upstream=` (the upstream commit it was built against, when known) and
  `prompt-sha256=` (hash of the prompt that produced it — `re-apply` compares
  this against the current prompt to tell whether the prompt changed).
- `check` (optional) — a shell command run in `work/` to verify the fork
  after `re-apply`. Without it, `re-apply` falls back to `make test` if the
  fork's Makefile has a `test` target, else reports the result as
  *unverified*.
- `{docs}.md` (where present) — the background research/rationale
  behind that fork's prompts; not required for the scripts to work, just the
  paper trail for why each prompt exists.
- `work/` — created by the scripts below, gitignored. A local clone of the
  fork remote where prompts actually get applied. Safe to delete and
  re-clone at any time; nothing you can't reproduce lives here.

## Scripts, and what order to run them in

The scripts live in `scripts/` (shared helpers in `scripts/lib/`) and take a
fork directory as their first positional argument (e.g. `scripts/apply
obscura`). `apply` and `re-apply` run a coding agent **locally** (`--engine
claude` (default) or `--engine oneclaw`) — there is no cloud-hosted agent
wired into this workflow, so none of this runs in CI. It's a manual,
human-triggered maintenance step: run it yourself when you want to set up or
refresh a fork. `apply`, `export-patches` and `re-apply` write
`<fork-dir>/patches/`; review and commit those changes in this repo
afterwards.

1. **`scripts/mirror <fork-dir>`** — one-time setup for a brand-new fork.
   Runs `gh repo fork` on upstream, naming/owning the result to match
   `fork.txt`, so the fork remote is created as an exact copy of upstream
   before any prompts exist or have been applied. Requires `gh` installed
   and authenticated. Since this only creates the fork, it's a no-op (gh
   just reports the fork already exists) if run again later.

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
   **any resulting changes are committed as `Apply <prompt>` and pushed to
   `<branch>` on origin immediately** — so progress survives even if a later
   prompt in the same run fails — and that commit is exported to
   `patches/`. Once at least one prompt has run, it uses `gh` to
   open a PR from `<branch>` into the fork's default branch (skipped if a
   PR already exists for that branch, or if `gh` isn't installed/authed).
   Use this:
   - the first time you apply prompts to a fork, on a new branch, or
   - to apply newly-added prompts on an existing, already-pushed branch
     without redoing already-applied ones (they're skipped via
     `.nqaf/prompts/`).

   Note: if a prompt is *changed* and re-applied on a branch that already
   carries it, the new commit (and so the exported patch) is only the delta
   over the earlier application. `apply` warns when this happens; prefer
   `re-apply` for changed prompts, which always produces one whole commit
   per feature.

3. **`scripts/export-patches <fork-dir>`** — one-time bootstrap for a fork
   whose prompts were applied before patches were stored here. Clones/fetches
   `work/` like `apply`, then for each prompt exports the most recent commit
   on the fork's default branch whose subject is exactly `Apply <prompt>`.
   The prompt hash is taken from that commit's `.nqaf/prompts/<prompt>`.
   Prompts with no such commit (never applied, or squash-merged under a
   different subject) are skipped with a warning; `re-apply` treats them as
   new.

4. **`scripts/re-apply [--engine claude|oneclaw] [--no-push] <fork-dir> [prompts/feature-NNN.md ...]`**
   — for pulling in new upstream commits. A no-op if `upstream/HEAD` is
   already contained in the fork's default branch. Otherwise it creates a
   fresh branch `nqaf-rebase-YYYY-MM-DD` (with a `-2`, `-3`, … suffix if
   that name is taken) from `upstream/HEAD` and, for each prompt in filename
   order:
   - **Patch stored, prompt unchanged, applies cleanly** (`git am -3`):
     kept as-is, no agent call. Outcome *clean*.
   - **Patch conflicts**: the am is aborted and the patch re-applied with
     `git apply --3way`, leaving conflict markers in the tree. The agent gets
     the prompt, the old patch and the conflict state, and repairs the
     conflicts, carrying the prior change forward. If it is at least 60%
     confident that starting over is easier, it discards the tree changes and
     re-implements from the prompt, using the old patch as a reference.
   - **Patch stored but the prompt changed** (hash differs from the
     `.base`): the old patch is applied the same way (clean or conflicted),
     then the agent is told the prompt changed and updates the carried-forward
     change to satisfy the new prompt — same 60% start-over rule.
   - **No patch**: the agent implements from the prompt, as `apply` does.

   The agent records its choice in `.nqaf/decisions/<prompt>` (`repair`,
   `rebuild` or `new`, plus a short rationale); those files are reported in
   the PR and never committed. Each feature becomes one `Apply <prompt>`
   commit, and its patch and `.base` are exported back to `patches/`.

   After all prompts, it runs the check once (`<fork-dir>/check`, else
   `make test`, else *unverified* — a fork without tests doesn't fail the
   run). It then pushes the branch to origin and opens a PR into the fork's
   default branch whose body lists each feature's outcome
   (clean/repaired/rebuilt/new), the agent's rationales, and the check
   result. The PR is opened even when the check fails, with a warning at the
   top of the body and in the title, and the script exits non-zero.
   `--no-push` skips the push and PR and just writes the PR body to
   `work/.git/nqaf-pr-body.md`.

   Run this periodically (whenever you know upstream has new commits you
   want).

`mirror` doesn't touch `work/` at all; it just creates the fork remote via
`gh repo fork`, so `gh` installed and authenticated is required for that step
(unlike the PR creation in `apply` and `re-apply`, which is skipped rather
than required if `gh` isn't available).

## Quick reference

| Situation | Run |
|---|---|
| Setting up a brand-new fork for the first time | `scripts/mirror <dir>` then `scripts/apply <dir> <branch>` |
| Adding a newly-written prompt to an already-applied branch | `scripts/apply <dir> <branch> prompts/feature-NNN.md` |
| Existing fork with no `patches/` yet | `scripts/export-patches <dir>` |
| Upstream has new commits you want to pick up | `scripts/re-apply <dir>` |
