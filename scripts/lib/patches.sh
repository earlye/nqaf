# shellcheck shell=bash
# Shared helpers for storing per-feature patches in this repo.
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
  git -C "$work" format-patch -1 --stdout --no-signature "$commit" > "$dir/$feature.patch"
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
