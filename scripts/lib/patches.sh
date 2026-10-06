# shellcheck shell=bash
# Shared helpers: per-feature patch storage, local-file exclusion, and PR
# attribution.
# Sourced by scripts/apply, scripts/export-patches, scripts/re-apply and
# scripts/rebuild.

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# combine_applications <work-dir> <commit> <prompt-name> — prints the commit
# to export for <prompt-name>, given its latest "Apply <prompt-name>" commit.
#
# A prompt applied again on a branch that already had it produces a commit
# that is only the delta over the earlier application. Walking back along
# first parents, if every commit down to the first application is either an
# "Apply <prompt-name>" commit or touches no files, this builds (with
# commit-tree, so no ref changes) one commit with the last application's tree
# on the first application's parent. If another commit sits in between, the
# feature can't be isolated, so it prints <commit> unchanged and warns.
combine_applications() {
  local work="$1" last="$2" name="$3"
  local first="$last" p subject count=1

  # first's parent already carries this prompt: find the previous application.
  while git -C "$work" cat-file -e "$first^:.nqaf/prompts/$name" 2>/dev/null; do
    p="$(git -C "$work" rev-parse "$first^")"
    while :; do
      subject="$(git -C "$work" log -1 --format=%s "$p")"
      [ "$subject" = "Apply $name" ] && break
      if git -C "$work" rev-parse -q --verify "$p^2" >/dev/null \
         || ! git -C "$work" diff --quiet "$p^" "$p" 2>/dev/null; then
        echo "Warning: ${name%.md}.patch is incremental over an earlier application of $name," \
          "and can't be combined with it because $(git -C "$work" rev-parse --short "$p")" \
          "('$subject') sits between them; re-apply will likely need the agent to repair it" >&2
        echo "$last"
        return
      fi
      p="$(git -C "$work" rev-parse "$p^")"
    done
    first="$p"
    count=$((count + 1))
  done

  if [ "$first" = "$last" ]; then
    echo "$last"
    return
  fi
  echo "Combining $count applications of $name" \
    "($(git -C "$work" rev-parse --short "$first")..$(git -C "$work" rev-parse --short "$last"))" >&2
  # Author/committer copied from the last application, so re-exporting the
  # same history yields the same commit.
  local an ae ad cn ce cd
  {
    IFS= read -r an; IFS= read -r ae; IFS= read -r ad
    IFS= read -r cn; IFS= read -r ce; IFS= read -r cd
  } < <(git -C "$work" log -1 --date=raw --format='%an%n%ae%n%ad%n%cn%n%ce%n%cd' "$last")
  GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
  GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cd" \
    git -C "$work" commit-tree "$last^{tree}" -p "$first^" -m "Apply $name"
}

# export_patch <work-dir> <commit> <prompt-name> <patches-dir> [upstream-sha]
#
# Writes <patches-dir>/feature-NNN.patch (format-patch of <commit>, combined
# with earlier applications of the same prompt where possible — see
# combine_applications) and feature-NNN.base (parent=, upstream=,
# prompt-sha256=). The prompt hash is taken from the .nqaf/prompts/<prompt-name>
# copy inside <commit>, so it describes exactly the prompt that commit was
# produced from. If no upstream sha is given, it falls back to the merge-base
# with upstream/HEAD when that ref exists, and is omitted otherwise.
export_patch() {
  local work="$1" commit="$2" name="$3" dir="$4" upstream="${5:-}"
  local feature="${name%.md}"
  local parent hash

  commit="$(combine_applications "$work" "$commit" "$name")"
  mkdir -p "$dir"
  # .claude/ holds per-checkout agent settings; older forks committed it, but
  # it never belongs in a stored patch.
  git -C "$work" format-patch --stdout --no-signature "$commit^!" -- . ':(exclude).claude' \
    > "$dir/$feature.patch"
  parent="$(git -C "$work" rev-parse "$commit^")"
  hash="$(git -C "$work" show "$commit:.nqaf/prompts/$name" | sha256_of)"

  if [ -z "$upstream" ] && git -C "$work" rev-parse -q --verify upstream/HEAD >/dev/null; then
    upstream="$(git -C "$work" merge-base "$commit" upstream/HEAD || true)"
  fi

  {
    echo "parent=$parent"
    [ -n "$upstream" ] && echo "upstream=$upstream"
    echo "prompt-sha256=$hash"
  } > "$dir/$feature.base"

  echo "Exported $feature.patch (+ .base) from $(git -C "$work" rev-parse --short "$commit")"
}

# base_value <base-file> <key> — prints the value of key=value, or nothing.
base_value() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n1
}

# fetch_upstream_default <work-dir> — fetches only upstream's default branch
# (no tags, no other branches) and points upstream/HEAD at it.
fetch_upstream_default() {
  local branch
  branch="$(git -C "$1" ls-remote --symref upstream HEAD \
    | sed -n 's@^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$@\1@p')"
  if [ -z "$branch" ]; then
    echo "Couldn't determine upstream's default branch" >&2
    return 1
  fi
  git -C "$1" fetch --quiet --no-tags upstream "+refs/heads/$branch:refs/remotes/upstream/$branch"
  git -C "$1" symbolic-ref refs/remotes/upstream/HEAD "refs/remotes/upstream/$branch"
}

# exclude_local_files <work-dir> — keeps the agent settings file and agent
# decision files out of `git add -A` (via .git/info/exclude).
exclude_local_files() {
  local exclude_file
  exclude_file="$(git -C "$1" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$1/$exclude_file" ;; esac
  mkdir -p "$(dirname "$exclude_file")"
  for pattern in '.claude/settings.json' '.nqaf/decisions/'; do
    grep -qxF "$pattern" "$exclude_file" 2>/dev/null || echo "$pattern" >> "$exclude_file"
  done
}

# unstage_local_files <work-dir> — info/exclude doesn't stop changes to a file
# the fork already tracks from being staged; drop them from the index. (The
# tracked copy is left for the user to remove from the fork.)
unstage_local_files() {
  git -C "$1" reset -q -- .claude/settings.json 2>/dev/null || true
}

# model_display <model-id> — human name for the PR attribution line.
model_display() {
  case "$1" in
    claude-opus-5-5) echo "Opus 5.5" ;;
    claude-sonnet-5-5) echo "Sonnet 5.5" ;;
    claude-fable-5-1) echo "Fable 5.1" ;;
    claude-haiku-4-5*) echo "Haiku 4.5" ;;
    *) echo "$1" ;;
  esac
}

# attribution_line <engine> <model-id> — first line of every PR body.
# oneclaw is not given a model (its model flag is unknown), so it reports
# "unspecified model" regardless of --model.
attribution_line() {
  case "$1" in
    claude) echo "** This is 🤖 Claude ($(model_display "$2")): **" ;;
    oneclaw) echo "** This is 🤖 OneClaw (unspecified model): **" ;;
    *) echo "** This is 🤖 $1 (unspecified model): **" ;;
  esac
}

# resolve_model <engine> <model-id> — prints the model to use (claude
# defaults to claude-opus-5-5), warning when --model can't be honoured.
resolve_model() {
  case "$1" in
    claude) echo "${2:-claude-opus-5-5}" ;;
    *)
      [ -n "$2" ] && echo "Warning: --model is not passed to --engine $1; ignoring '$2'" >&2
      echo ""
      ;;
  esac
}
