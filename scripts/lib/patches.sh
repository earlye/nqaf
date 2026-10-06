# shellcheck shell=bash
# Shared helpers: per-feature patch storage, local-file exclusion, and PR
# attribution.
# Sourced by scripts/apply, scripts/export-patches and scripts/re-apply.

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# export_patch <work-dir> <commit> <prompt-name> <patches-dir> [upstream-sha]
#
# Writes <patches-dir>/feature-NNN.patch (format-patch of <commit>) and
# feature-NNN.base (parent=, upstream=, prompt-sha256=). The prompt hash is
# taken from the .nqaf/prompts/<prompt-name> copy inside <commit>, so it
# describes exactly the prompt that commit was produced from. If no upstream
# sha is given, it falls back to the merge-base with upstream/HEAD when that
# ref exists, and is omitted otherwise.
export_patch() {
  local work="$1" commit="$2" name="$3" dir="$4" upstream="${5:-}"
  local feature="${name%.md}"
  local parent hash

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

  # A prompt re-applied on a branch that already had it produces a commit that
  # is only the delta over the earlier application, not the whole feature.
  if git -C "$work" cat-file -e "$commit^:.nqaf/prompts/$name" 2>/dev/null; then
    echo "Warning: $feature.patch is incremental over an earlier application of $name;" \
      "re-apply will likely need the agent to repair it" >&2
  fi
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
