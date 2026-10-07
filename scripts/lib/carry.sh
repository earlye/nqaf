# shellcheck shell=bash
# upstream and fork are set by the sourcing script.
# shellcheck disable=SC2154
# Shared steps for carrying a fork's features onto upstream: preparing work/,
# replaying each feature (stored patch, or the agent), the check gate, the PR
# body, and the push/PR. Sourced by scripts/re-apply and scripts/rebuild,
# after lib/patches.sh and lib/limits.sh.
#
# Callers set FORK_DIR, CONFIG_DIR, WORK_DIR, PATCHES_DIR, ENGINE, MODEL,
# upstream and fork before using these. They communicate through globals:
# prepare_work_dir sets upstream_head and default_branch; carry_feature
# appends to names/outcomes/paths/rationales; run_check sets check_result,
# check_desc and check_log.

declare -a names outcomes paths rationales

# `claude -p` kills background tasks after 600s by default; the agent may
# delegate long implementation work to one, so wait for it instead.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

# prepare_work_dir — clones the fork into work/ if needed (else points origin
# at fork.txt), points the upstream remote at upstream.txt, fetches both, and
# sets upstream_head and default_branch (the fork's).
prepare_work_dir() {
  if [ ! -d "$WORK_DIR/.git" ]; then
    echo "Cloning $fork → $WORK_DIR"
    git clone --quiet --no-tags "$fork" "$WORK_DIR"
  else
    git -C "$WORK_DIR" remote set-url origin "$fork"
  fi

  # Ensure upstream remote exists
  if git -C "$WORK_DIR" remote get-url upstream &>/dev/null; then
    git -C "$WORK_DIR" remote set-url upstream "$upstream"
  else
    git -C "$WORK_DIR" remote add upstream "$upstream"
  fi

  echo "Fetching origin and upstream..."
  git -C "$WORK_DIR" fetch --quiet --no-tags origin
  fetch_upstream_default "$WORK_DIR"

  upstream_head="$(git -C "$WORK_DIR" rev-parse upstream/HEAD)"
  default_branch="$(git -C "$WORK_DIR" symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')"
}

# reset_work_dir — work/ is disposable: drop any half-finished state from an
# earlier run.
reset_work_dir() {
  git -C "$WORK_DIR" am --abort 2>/dev/null || true
  git -C "$WORK_DIR" reset --hard
  git -C "$WORK_DIR" clean -fd
  rm -rf "$WORK_DIR/.nqaf/decisions"

  # Agent decision files are read by this script and reported in the PR body,
  # and the agent settings file is per-checkout; neither is ever committed.
  exclude_local_files "$WORK_DIR"
}

# unique_branch <prefix> — prints <prefix>-YYYY-MM-DD, with a -2, -3, …
# suffix if that name exists locally or on origin.
unique_branch() {
  local branch candidate n=1
  branch="$1-$(date +%Y-%m-%d)"
  candidate="$branch"
  while git -C "$WORK_DIR" show-ref --verify --quiet "refs/heads/$candidate" \
     || git -C "$WORK_DIR" show-ref --verify --quiet "refs/remotes/origin/$candidate"; do
    n=$((n + 1))
    candidate="$branch-$n"
  done
  echo "$candidate"
}

# .claude/settings.json exists only while the agent runs, so it can never be
# swept into a commit or block `git am` from creating a tracked copy.
run_agent() {
  local text="$1" settings="$WORK_DIR/.claude/settings.json" created=0
  if [ ! -e "$settings" ]; then
    mkdir -p "$WORK_DIR/.claude"
    cat > "$settings" <<'EOF'
{
  "defaultMode": "bypassPermissions"
}
EOF
    created=1
  fi
  case "$ENGINE" in
    oneclaw) (cd "$WORK_DIR" && set -x && run_limited oneclaw run --prompt "$text") ;;
    claude)  (cd "$WORK_DIR" && set -x && run_limited claude --dangerously-skip-permissions --verbose --model "$MODEL" -p "$text") ;;
    *) echo "Unknown engine: $ENGINE" >&2; exit 1 ;;
  esac
  if [ "$created" -eq 1 ]; then
    rm -f "$settings"
    rmdir "$WORK_DIR/.claude" 2>/dev/null || true
  fi
}

START_OVER_RULE="If you judge, with at least 60% confidence, that starting over is easier
than repairing, then instead discard the working tree changes
(\`git reset --hard HEAD && git clean -fd\`) and re-implement the feature
from the prompt below, using the old patch as a reference for how it was
done before.

Do not commit. Leave no conflict markers. Ignore \`.nqaf/prompts/\`; the
script maintains it."

# carry_feature <prompt> — adds one "Apply <prompt>" commit on HEAD: the
# stored patch if it applies cleanly and its prompt is unchanged, else the
# agent's repair, update or fresh implementation. Exports the commit back to
# PATCHES_DIR and records the outcome.
carry_feature() {
  local prompt="$1"
  local prompt_name feature patch base decision_file prompt_hash
  local outcome="" path="" rationale="" prompt_changed state apply_log unmerged task decision
  prompt_name="$(basename "$prompt")"
  feature="${prompt_name%.md}"
  patch="$PATCHES_DIR/$feature.patch"
  base="$PATCHES_DIR/$feature.base"
  decision_file="$WORK_DIR/.nqaf/decisions/$prompt_name"
  prompt_hash="$(sha256_of < "$prompt")"
  rm -f "$decision_file"
  exclude_build_outputs "$WORK_DIR"

  if [ ! -f "$patch" ]; then
    path="no patch"
    echo "== $prompt_name: no stored patch; implementing from the prompt"
    run_agent "This fix may already be present in this codebase (merged in from
upstream, or implemented independently). Before making any changes: inspect
the relevant code and determine whether the fix described below has already
been fully implemented.

- If it has already been fully implemented, make no code changes — just
  confirm that it is already in place.
- If it has not been fully implemented (in whole or in part), implement it
  as described below.

Do not commit. As your very last step, write \`.nqaf/decisions/$prompt_name\`:
the first line is exactly \`new\`, followed by a short rationale (a few lines).

---

$(cat "$prompt")"
    outcome="new"

  else
    prompt_changed=0
    [ "$(base_value "$base" prompt-sha256)" = "$prompt_hash" ] || prompt_changed=1

    # --keep-cr: git am strips CRs by default, so patches touching CRLF files
    # would never apply. (git apply, below, keeps them already.)
    if git -C "$WORK_DIR" am -3 --keep-cr "$patch" >/dev/null 2>&1; then
      if [ "$prompt_changed" -eq 0 ]; then
        echo "== $prompt_name: stored patch applied cleanly"
        path="patch, clean"
        outcome="clean"
        # An older stored patch may carry build output; drop it from the
        # commit (and so from the re-exported patch).
        drop_build_outputs "$WORK_DIR" HEAD^
        if ! git -C "$WORK_DIR" diff --cached --quiet HEAD; then
          git -C "$WORK_DIR" commit -q --amend --no-edit
          path="patch, clean (build output dropped)"
        fi
      else
        # Un-commit, so the agent's update lands in the same single commit.
        git -C "$WORK_DIR" reset --soft HEAD^
        state="The old patch applied cleanly; its changes are staged in the working
tree, uncommitted."
      fi
    else
      git -C "$WORK_DIR" am --abort
      apply_log="$(git -C "$WORK_DIR" apply --3way "$patch" 2>&1)" || true
      unmerged="$(git -C "$WORK_DIR" diff --name-only --diff-filter=U)"
      if [ -n "$unmerged" ]; then
        state="The old patch did not apply cleanly. \`git apply --3way\` has applied
what it could (staged) and left conflict markers (<<<<<<< ======= >>>>>>>)
in these files:

$unmerged"
      elif git -C "$WORK_DIR" diff --cached --quiet; then
        state="The old patch could not be applied at all; the working tree is
unchanged from HEAD."
      else
        state="The old patch did not apply via \`git am\`, but \`git apply --3way\`
applied it without conflict markers (staged). Check that the result is
correct."
      fi
      state="$state

Output of \`git apply --3way\`:

$apply_log"
    fi

    if [ -z "$outcome" ]; then
      if [ "$prompt_changed" -eq 1 ]; then
        path="patch, prompt changed"
        echo "== $prompt_name: prompt changed since the stored patch; running agent to update it"
        task="The feature prompt has CHANGED since that patch was produced. The old
prompt text is the \`.nqaf/prompts/$prompt_name\` hunk inside the patch file
(also \`git show origin/HEAD:.nqaf/prompts/$prompt_name\`, if present). Resolve
any conflicts, then update the carried-forward change so that it satisfies
the NEW prompt below."
      else
        path="patch, conflict"
        echo "== $prompt_name: stored patch conflicts; running agent to repair it"
        task="Repair the conflicts, carrying the prior change forward onto this newer
code so that it still does what the prompt below asks."
      fi
      run_agent "You are carrying a previously-implemented change forward onto a newer
upstream version of this codebase. HEAD is the new upstream plus the
features carried forward before this one.

The change was produced from the feature prompt at the end of this message.
Its previous implementation, as a git patch against an older base, is:

  $patch

$state

Your task: $task

$START_OVER_RULE As your very last step, write your decision to
\`.nqaf/decisions/$prompt_name\`: the first line is exactly \`repair\` or
\`rebuild\`, followed by a short rationale (a few lines).

---

$(cat "$prompt")"
    fi
  fi

  if [ "$outcome" != "clean" ]; then
    if [ -f "$decision_file" ]; then
      decision="$(head -n1 "$decision_file" | tr -d '[:space:]')"
      rationale="$(tail -n +2 "$decision_file")"
    else
      decision=""
      rationale="(agent wrote no decision file)"
    fi
    case "$decision" in
      repair) outcome="repaired" ;;
      rebuild) outcome="rebuilt" ;;
      new) outcome="new" ;;
      *) [ -n "$outcome" ] || outcome="unknown" ;;
    esac
    rm -rf "$WORK_DIR/.nqaf/decisions"

    mkdir -p "$WORK_DIR/.nqaf/prompts"
    cp "$prompt" "$WORK_DIR/.nqaf/prompts/$prompt_name"
    git -C "$WORK_DIR" add -A
    unstage_local_files "$WORK_DIR"
    drop_build_outputs "$WORK_DIR"
    if git -C "$WORK_DIR" diff --cached --check 2>&1 | grep -q 'conflict marker'; then
      echo "Warning: conflict markers remain after $prompt_name" >&2
      outcome="$outcome (CONFLICT MARKERS REMAIN)"
    fi
    git -C "$WORK_DIR" commit -q -m "Apply $prompt_name"
  fi

  export_patch "$WORK_DIR" HEAD "$prompt_name" "$PATCHES_DIR" "$upstream_head"

  names+=("$prompt_name")
  outcomes+=("$outcome")
  paths+=("$path")
  rationales+=("$rationale")
}

# run_check — final check gate: <fork-dir>/check if present, else `make test`
# if the Makefile has a test target, else unverified. A missing check is not a
# failure. The check runs under run_limited; hitting the memory cap counts as
# a failure.
run_check() {
  local makefile="" f check_status="" note
  check_log="$(git -C "$WORK_DIR" rev-parse --absolute-git-dir)/nqaf-check.log"
  for f in GNUmakefile makefile Makefile; do
    [ -f "$WORK_DIR/$f" ] && { makefile="$f"; break; }
  done
  if [ -f "$CONFIG_DIR/check" ]; then
    check_desc="\`$FORK_DIR/check\`"
    echo "Running check: $(cat "$CONFIG_DIR/check")"
    check_status=0
    (cd "$WORK_DIR" && run_limited bash -c "$(cat "$CONFIG_DIR/check")") >"$check_log" 2>&1 \
      || check_status=$?
  elif [ -n "$makefile" ] && grep -qE '^test[[:space:]]*:' "$WORK_DIR/$makefile"; then
    check_desc="\`make test\`"
    echo "Running check: make test"
    check_status=0
    (cd "$WORK_DIR" && run_limited make test) >"$check_log" 2>&1 || check_status=$?
  else
    check_desc="none (no \`$FORK_DIR/check\` and no Makefile \`test\` target)"
    check_result="unverified"
    : > "$check_log"
  fi
  if [ -n "$check_status" ]; then
    if [ "$check_status" -eq 0 ]; then
      check_result="pass"
    else
      check_result="fail"
      if [ "$check_status" -eq "$LIMIT_KILLED_STATUS" ]; then
        note="Check was killed (SIGKILL) — most likely it hit the NQAF_MEMORY_MAX=$NQAF_MEMORY_MAX memory cap."
        echo "$note" >> "$check_log"
        echo "$note" >&2
      fi
    fi
  fi
  echo "Check result: $check_result (log: $check_log)"
}

# write_pr_body <file> <intro> <branch> — the PR body: attribution, check
# warning, <intro>, how to review and land it, the per-feature outcome table,
# agent rationales, and the check output if it failed.
write_pr_body() {
  local i slug
  slug="$(github_slug "$fork")"
  {
    attribution_line "$ENGINE" "$MODEL"
    echo
    if [ "$check_result" = "fail" ]; then
      echo "> [!CAUTION]"
      echo "> **The check FAILED.** Do not merge until it passes. Output is at the bottom."
      echo
    fi
    echo "$2"
    echo
    echo "**Review:** [patch-only diff (upstream base → this branch)](https://github.com/$slug/compare/$upstream_head...$3)" \
      "— just the fork's features on top of upstream \`$(git -C "$WORK_DIR" rev-parse --short "$upstream_head")\`." \
      "This PR's own diff also includes every upstream change since \`$default_branch\` was last rebuilt."
    echo
    echo "**Land with a merge commit:** \`scripts/merge-pr $FORK_DIR <this PR's number>\`." \
      "The branch ends in a merge of the old \`$default_branch\` (\`-s ours\`; its tree is the rebuilt one)," \
      "so it merges cleanly; squash or rebase would drop that ancestry and the next re-apply would" \
      "not see upstream as merged."
    echo
    echo "**Check:** $check_result — $check_desc"
    echo
    echo "| Feature | Path | Outcome |"
    echo "|---|---|---|"
    for i in "${!names[@]}"; do
      echo "| \`${names[$i]}\` | ${paths[$i]} | **${outcomes[$i]}** |"
    done
    echo
    echo "Outcomes: **clean** = stored patch applied with no agent; **repaired** = agent fixed up the stored patch; **rebuilt** = agent re-implemented from the prompt; **new** = no stored patch, implemented from the prompt."
    echo
    echo "## Decisions"
    for i in "${!names[@]}"; do
      [ "${outcomes[$i]}" = "clean" ] && continue
      echo
      echo "### \`${names[$i]}\` — ${outcomes[$i]}"
      echo
      printf '%s\n' "${rationales[$i]}" | sed 's/^/> /'
    done
    if [ "$check_result" = "fail" ]; then
      echo
      echo "## Check output (last 100 lines)"
      echo
      echo '```'
      tail -n 100 "$check_log"
      echo '```'
    fi
  } > "$1"
}

# print_summary — per-feature outcomes and the check result.
print_summary() {
  local i
  echo
  echo "Summary:"
  for i in "${!names[@]}"; do
    printf '  %-20s %s\n' "${names[$i]}" "${outcomes[$i]}"
  done
  echo "  check: $check_result"
  echo "Updated patches are in $PATCHES_DIR — review and commit them in this repo."
}

# supersede_default_branch — makes the fork's current default branch an
# ancestor of HEAD without changing HEAD's tree (`git merge -s ours`), so the
# PR merges cleanly and, once landed with a merge commit, upstream_head is an
# ancestor of the default branch. Run after the Apply commits are built and
# their patches exported (export_patch only reads each Apply commit, so the
# merge never reaches a stored patch). Skipped if already an ancestor; exits
# if the tree changes.
supersede_default_branch() {
  local target="origin/$default_branch" before after
  git -C "$WORK_DIR" fetch --quiet --no-tags origin "$default_branch"
  if git -C "$WORK_DIR" merge-base --is-ancestor "$target" HEAD; then
    echo "$target is already an ancestor of HEAD; no supersede merge needed"
    return 0
  fi
  before="$(git -C "$WORK_DIR" rev-parse 'HEAD^{tree}')"
  git -C "$WORK_DIR" merge -q -s ours --no-edit \
    -m "NQAF: supersede previous fork $default_branch" "$target"
  after="$(git -C "$WORK_DIR" rev-parse 'HEAD^{tree}')"
  if [ "$before" != "$after" ]; then
    echo "BUG: the supersede merge changed the tree ($before → $after); aborting before push" >&2
    exit 1
  fi
  echo "Merged $target into HEAD with -s ours (tree unchanged)"
}

# close_superseded_prs <new-pr-url> — closes this user's other open PRs in the
# fork whose head is an nqaf-rebase-*/nqaf-rebuild-* branch in the fork
# itself, commenting with a pointer to <new-pr-url> and deleting the branch.
# Failures are reported, not fatal.
close_superseded_prs() {
  local new_url="$1" slug n head comment
  slug="$(github_slug "$fork")"
  comment="$(attribution_line "$ENGINE" "$MODEL")

Superseded by $new_url, which carries the fork's features onto a newer upstream. Closing this PR and deleting its branch."
  gh pr list --repo "$slug" --state open --author @me --limit 100 \
      --json number,headRefName,isCrossRepository,url \
      --jq ".[] | select(.isCrossRepository | not)
                | select(.headRefName | test(\"^nqaf-(rebase|rebuild)-\"))
                | select(.url != \"$new_url\")
                | \"\\(.number) \\(.headRefName)\"" \
    | while read -r n head; do
        echo "Closing superseded PR #$n ($head)"
        gh pr close "$n" --repo "$slug" --delete-branch --comment "$comment" \
          || echo "Failed to close superseded PR #$n" >&2
      done \
    || echo "Couldn't list open PRs to close superseded ones" >&2
}

# push_and_open_pr <branch> <title> <pr-body-file> — merges the old default
# branch in (supersede_default_branch), then pushes <branch> to origin (a
# normal push), opens a PR into the fork's default branch and closes the PRs
# it supersedes, unless --no-push. A missing gh or a failed PR creation is
# reported, not fatal.
push_and_open_pr() {
  local branch="$1" title="$2" pr_body="$3" pr_url
  supersede_default_branch
  if [ "$PUSH" -eq 0 ]; then
    echo "--no-push: not pushing $branch or opening a PR. PR body written to $pr_body"
  elif ! command -v gh >/dev/null 2>&1; then
    git -C "$WORK_DIR" push -u origin "$branch"
    echo "gh not found; pushed $branch but skipped PR creation. PR body written to $pr_body" >&2
  else
    git -C "$WORK_DIR" push -u origin "$branch"
    echo "Setting gh default repo to $fork"
    (cd "$WORK_DIR" && gh repo set-default "$fork")
    if pr_url="$(cd "$WORK_DIR" && gh pr create \
      --base "$default_branch" \
      --head "$branch" \
      --title "$title" \
      --body-file "$pr_body")"; then
      echo "$pr_url"
      pr_url="$(tail -n1 <<<"$pr_url")"
      close_superseded_prs "$pr_url"
    else
      echo "PR creation failed — branch is still pushed. PR body is at $pr_body" >&2
    fi
  fi
}
