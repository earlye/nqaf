# Purge the 75MB obscura feature-004 patch from main's history

## Context

Commit `19a537e` ("WIP") on `main` added a 75MB version of `obscura/patches/feature-004.patch`. Pushing it triggered GitHub's warning: `GH001: Large files detected`.

The patch is bloated because the agent's build output was committed with the feature. While carrying obscura's feature-004 forward, the agent's build dir `target-headchk/release/` (~583 files, plus `CACHEDIR.TAG`) was swept into the `Apply feature-004.md` commit by `git add -A` in `carry_feature`, and then exported into the patch.

Replacing the file with a clean patch in a new commit is not enough. The 75MB blob would stay in `main`'s history, so **every clone of nqaf would carry a 75MB blob forever**. The decision is to rewrite history so the blob is gone.

## Blocked by

- The build-output exclusion fix: `exclude_build_outputs` / `drop_build_outputs` in `scripts/lib/patches.sh`, called from `carry_feature`. It was written (uncommitted) in `.claude/worktrees/mergeable-rebase-prs` on branch `earlye/a6fed9f44178/mergeable-rebase-prs`, and has to be in the main checkout's scripts before a clean feature-004 patch can be produced. When a stored patch applies cleanly, that fix drops the artifacts and amends the commit, so the re-exported patch is clean.

## Next steps

1. Land the build-output exclusion fix in the main checkout.
2. Re-run obscura (`scripts/re-apply obscura`) to re-export a clean `feature-004.patch` (and `.base`).
3. Rewrite history so that the 75MB version never appears in `main`. For example, rewrite `19a537e` so it contains the clean patch, or use `git filter-repo` to drop that blob and substitute the clean one. Verify with:
   `git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' | awk '$1=="blob" && $2>50000000'`
4. Force-push `main` with `--force-with-lease`. Anyone else with a clone (other sessions, other machines) must reset to the new `main`.

## Why not Git LFS

GitHub allows LFS for a single path, but switching `obscura/patches/feature-004.patch` to LFS only affects new commits. The 75MB blob already in `19a537e` stays in history unless it is rewritten (e.g. `git lfs migrate import`), so LFS still needs the same rewrite and force-push. It also adds a git-lfs dependency for cloning and uses LFS storage/bandwidth quota, all to store build output that shouldn't be in the patch at all.

## Resolution (2026-11-24)

Correction: the 75MB patch first appeared in `81dc084` ("working through getting apply-all to work."), not `19a537e`. `19a537e` only changed the patch's `From <sha>` line, which created a second 75MB blob. Both blobs had to go.

Rather than re-running `scripts/re-apply obscura`, the clean patch was regenerated offline. In a scratch clone of the fork, the old patch was applied with `git am` onto the `.base` parent (`9049f9cd`), `target-headchk/` was removed, the commit was amended, and the patch was re-exported with `export_patch`'s `format-patch` command. The result is 21,222 bytes (it was 75,216,075), and its 9 real file diffs are byte-identical to the originals. `feature-004.base` did not change.

`git filter-branch --index-filter` swapped both blobs for clean ones in every commit from `81dc084` to the tip (12 commits). The rewrite kept author, committer and message metadata, but the GitHub signatures on #17 and #18 were lost. `main` was force-pushed with `--force-with-lease=main:ac92b4f` (`ac92b4f`, an issue-tracking commit pushed during the rewrite, was replayed on top). Old→new: `81dc084`→`198176b`, `19a537e`→`f695699`, `6041039`→`9244b05`, `ac92b4f`→`aff2bf9`. Other clones must reset to the new `main`.
