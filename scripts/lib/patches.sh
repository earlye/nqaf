# shellcheck shell=bash
# Shared helpers: per-feature patch storage, local-file exclusion, and PR
# attribution.
# Sourced by scripts/apply, scripts/export-patches, scripts/merge-pr,
# scripts/re-apply and scripts/rebuild.

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

# Directory names that hold build output, never source: matched at any depth
# by exclude_build_outputs (as gitignore patterns) and drop_build_outputs.
BUILD_OUTPUT_DIRS=(target 'target-*' node_modules __pycache__ .venv)

# is_build_output_name <dir-name> — true if <dir-name> matches BUILD_OUTPUT_DIRS.
is_build_output_name() {
  local pattern
  for pattern in "${BUILD_OUTPUT_DIRS[@]}"; do
    # shellcheck disable=SC2053  # glob match is intended
    [[ "$1" == $pattern ]] && return 0
  done
  return 1
}

# exclude_build_outputs <work-dir> — (re)writes a marked block of
# BUILD_OUTPUT_DIRS patterns in .git/info/exclude so `git add -A` skips build
# output. A pattern is left out if HEAD already tracks a directory of that
# name, so new files the agent adds there are not silently ignored (if they
# are build output, drop_build_outputs still catches them).
exclude_build_outputs() {
  local work="$1" exclude_file pattern name tmp skip
  local -a tracked
  local begin='# nqaf build outputs (managed by scripts/lib/patches.sh)' end='# end nqaf build outputs'
  exclude_file="$(git -C "$work" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$work/$exclude_file" ;; esac
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  mapfile -t tracked < <(git -C "$work" ls-tree -r -d --name-only HEAD | awk -F/ '{ print $NF }' | sort -u)
  tmp="$exclude_file.nqaf.$$"
  {
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$exclude_file"
    echo "$begin"
    for pattern in "${BUILD_OUTPUT_DIRS[@]}"; do
      skip=0
      for name in "${tracked[@]}"; do
        # shellcheck disable=SC2053  # glob match is intended
        [[ "$name" == $pattern ]] && { skip=1; break; }
      done
      if [ "$skip" -eq 1 ]; then
        echo "Note: HEAD tracks a '$pattern' directory; not ignoring it (new files there are still filtered after staging)" >&2
      else
        echo "$pattern/"
      fi
    done
    echo "$end"
  } > "$tmp"
  mv "$tmp" "$exclude_file"
}

# drop_build_outputs <work-dir> [<base>] — unstages newly-added files (staged,
# absent from <base>, default HEAD) that live under a build-output directory:
# one named in BUILD_OUTPUT_DIRS, or one holding a CACHEDIR.TAG (the
# cache-directory spec, https://bford.info/cachedir/). A directory that
# already exists in <base> is never treated as build output: upstream tracks
# it. The files stay on disk, and each dropped directory is added to
# .git/info/exclude so later `git add -A` runs skip it. Prints a warning per
# directory; returns 0 whether or not anything was dropped.
drop_build_outputs() {
  local work="$1" base="${2:-HEAD}"
  local path dir prefix comp exclude_file n
  local -A verdict=() dropped=()
  local -a comps

  while IFS= read -r -d '' path; do
    IFS=/ read -r -a comps <<<"$path"
    prefix=""
    for comp in "${comps[@]:0:${#comps[@]}-1}"; do
      dir="${prefix:+$prefix/}$comp"
      prefix="$dir"
      if [ -z "${verdict[$dir]+x}" ]; then
        verdict[$dir]=0
        if ! git -C "$work" cat-file -e "$base:$dir" 2>/dev/null; then
          if is_build_output_name "$comp" \
             || [ -f "$work/$dir/CACHEDIR.TAG" ] \
             || git -C "$work" cat-file -e ":$dir/CACHEDIR.TAG" 2>/dev/null; then
            verdict[$dir]=1
          fi
        fi
      fi
      if [ "${verdict[$dir]}" -eq 1 ]; then
        dropped[$dir]=$(( ${dropped[$dir]:-0} + 1 ))
        break
      fi
    done
  done < <(git -C "$work" diff --cached --name-only -z --no-renames --diff-filter=A "$base")

  [ "${#dropped[@]}" -gt 0 ] || return 0
  exclude_file="$(git -C "$work" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$work/$exclude_file" ;; esac
  for dir in "${!dropped[@]}"; do
    n="${dropped[$dir]}"
    echo "Warning: not committing $n new file(s) under build-output directory $dir/" >&2
    git -C "$work" rm -r -q --cached --ignore-unmatch -- "$dir"
    grep -qxF "/$dir/" "$exclude_file" 2>/dev/null || echo "/$dir/" >> "$exclude_file"
  done
}

# github_slug <git-url> — owner/repo for a github.com SSH or HTTPS URL.
github_slug() {
  sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##; s#/$##' <<<"$1"
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
