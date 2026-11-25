# nqaf: store per-feature patches and carry them forward on re-apply

## Context

nqaf stores only prompts (`<project>/prompts/feature-NNN.md`). When
upstream moves, `scripts/re-apply` tries `merge upstream/HEAD` +
`make test`, and on any failure resets to `upstream/HEAD` and re-runs
every prompt from scratch, without committing. Re-implementing every
feature on each upstream bump costs an agent run per feature, can drift
from the previously reviewed implementation, and throws away the
working diff we already had.

## Design

Store each feature's last diff in this repo and use it to carry the
fork forward, calling the agent only where needed.

1. **Storage**, committed here: `<project>/patches/feature-NNN.patch`
   (`git format-patch` of that feature's single commit) and
   `<project>/patches/feature-NNN.base` (`parent=`, `upstream=` if
   known, `prompt-sha256=` of the prompt that produced it).
2. **`scripts/apply`** exports each `Apply <prompt>` commit to
   `patches/` after committing it. Behaviour otherwise unchanged.
3. **`scripts/export-patches <dir>`** bootstraps existing forks: for
   each prompt, exports the newest `Apply <prompt>` commit on the
   fork's default branch, hashing that commit's
   `.nqaf/prompts/<prompt>`.
4. **`scripts/re-apply`** builds `nqaf-rebase-YYYY-MM-DD` (suffixed if
   taken) from `upstream/HEAD`, and for each prompt in order:
   - patch + unchanged prompt + `git am -3` clean → *clean*, no agent;
   - patch conflicts → `git apply --3way` leaves markers; agent repairs,
     carrying the prior change forward;
   - patch + changed prompt → apply as above, agent updates the change
     to the new prompt;
   - no patch → agent implements from the prompt (*new*).
   In the repair cases the agent starts over from the prompt (using the
   old patch as reference) if it is at least 60% confident that is
   easier. It writes `repair`/`rebuild`/`new` + rationale to
   `.nqaf/decisions/<prompt>` (not committed). Each feature becomes one
   `Apply <prompt>` commit, re-exported to `patches/`.
   A final check runs once: `<project>/check`, else `make test`, else
   *unverified* (not a failure). The branch is pushed and a PR opened
   into the fork's default branch listing per-feature outcomes,
   rationales and the check result; a failed check is flagged in the
   title and body but the PR is still opened. `--no-push` skips the
   push and PR.
5. **Docs**: README describes patches, `export-patches` and the new
   `re-apply`; the turso ADR's Consequences no longer says nqaf
   re-implements from scratch.

## Known limits

- If a changed prompt is re-applied with `apply` on a branch that
  already carries it, the new commit is only a delta; its exported
  patch won't apply on fresh upstream by itself, so `re-apply` falls
  back to the agent. `apply` warns when this happens.
- For features whose PRs were squash-merged, `export-patches` falls
  back to the merged PRs' `refs/pull/<N>/head` (via `gh`). Their
  `parent=` is the pre-squash parent, which isn't on the default
  branch.

## Follow-ups folded in

- `.claude/settings.json` is excluded via `.git/info/exclude`, never
  staged, and `.claude/` is excluded from exported patches. Forks that
  already track it keep it until the user removes it.
- PR bodies from `apply` and `re-apply` start with
  `** This is 🤖 <Harness> (<Model>): **`. `--model` is passed to
  `claude --model` (default `claude-opus-5-5`); oneclaw gets no model
  flag and reports `unspecified model`.
