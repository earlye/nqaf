# scripts: catch "hollow" feature patches that contain only the .nqaf prompt record

## Context

obscura's `feature-010.patch` (`Page::id` in the facade) has been prompt-only in every nqaf version. It touches only `.nqaf/prompts/feature-010.md`, so every re-apply silently dropped the feature, and `re-apply` reported it as "patch, clean". The c3 session spotted it while drafting obscura feature-012. A review found the cause:

- **How the fork PR ended up:** earlye-forks/obscura PR #2 (head 1a53dc7) has three commits:
  - `edcbee1 Apply feature-010.md`: the real change, facade `page.rs` +6 and `tests/page_id.rs` +18;
  - `528ba48 Removing feature-010.md to force re-apply`: deletes only the prompt;
  - `1a53dc7 Apply feature-010.md`: prompt only, because the agent found the code already present and changed nothing.
- **Why export missed the real change:** `export-patches` takes the newest "Apply" commit. `combine_applications` in `scripts/lib/patches.sh` should have merged both applications, but it only walks back while `first^` still contains the prompt, and the removal commit breaks that walk. Only the hollow commit was exported.
- **Why `apply` didn't catch it:** `scripts/apply` copies the prompt marker in before its "No changes" check, so that check can never fire on a first application.
- **feature-005 is also prompt-only, legitimately:** upstream now does public-suffix checks with the `psl` crate, which supersedes it. But nothing distinguishes "correctly superseded" from "silently lost".

feature-010's patch is being regenerated from `edcbee1`, and feature-005 is being marked superseded, separately. This issue covers the tooling guards.

## Proposed guards

1. **`scripts/apply`:** after the agent runs, fail when `git diff --cached --quiet -- . ':!.nqaf'` succeeds, meaning nothing changed outside `.nqaf/`, unless the agent records an explicit no-op decision (e.g. a `.nqaf/decisions/<prompt>` file with `noop: <reason>`).
2. **`export_patch` / `combine_applications`:**
   - treat commits that only delete or re-add a prompt as transparent when walking back;
   - refuse to export a patch that touches only `.nqaf/` unless the `.base` carries an explicit `noop=` marker.
3. **`re-apply`:** report a stored patch that touches only `.nqaf/` as "hollow" rather than "clean", and send it to the agent to verify or rebuild, instead of replaying it faithfully.

## Relevant files

- `scripts/lib/patches.sh`: `export_patch`, `combine_applications`
- `scripts/export-patches`
- `scripts/apply`: the prompt marker is copied before the "No changes" check
- `scripts/re-apply`: classifies a stored patch as clean or rebuilt
- `obscura/patches/feature-010.patch`, `obscura/patches/feature-005.patch`: the two hollow patches found so far
