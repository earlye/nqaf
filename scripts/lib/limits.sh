# shellcheck shell=bash
# Resource limits for the heavy steps (agent runs and the check), so a runaway
# build can't push the host into memory pressure or saturate its CPUs.
# Sourced by scripts/apply, scripts/re-apply and scripts/rebuild.
#
# NQAF_MEMORY_MAX  memory cap for each limited command (default 20G; any
#                  systemd MemoryMax= value, e.g. 12G or 60%)
# NQAF_CPU_QUOTA   CPU cap for each limited command (default 200%, i.e. two
#                  cores; any systemd CPUQuota= value)
# CARGO_BUILD_JOBS parallel cargo jobs (default 2; left alone if already set)
# GOFLAGS          gets -p=2 (parallel go builds) appended unless it already
#                  has a -p flag

: "${NQAF_MEMORY_MAX:=20G}"
: "${NQAF_CPU_QUOTA:=200%}"
: "${CARGO_BUILD_JOBS:=2}"
export CARGO_BUILD_JOBS
if ! [[ " ${GOFLAGS:-} " =~ [[:space:]]--?p[=[:space:]] ]]; then
  GOFLAGS="${GOFLAGS:+$GOFLAGS }-p=2"
fi
export GOFLAGS

# Exit status of a command killed by SIGKILL — what run_limited returns when
# the memory cap is hit, since OOMPolicy=kill kills the whole scope.
# shellcheck disable=SC2034 # read by lib/carry.sh
LIMIT_KILLED_STATUS=137

# No IOWeight: the io controller isn't delegated to systemd user managers by
# default, so it would be silently ignored. ionice -c3 only takes effect under
# the BFQ I/O scheduler.
limit_prefix=(nice -n 10)
command -v ionice >/dev/null 2>&1 && limit_prefix+=(ionice -c3)
if command -v systemd-run >/dev/null 2>&1 \
   && systemd-run --user --scope --quiet true >/dev/null 2>&1; then
  limit_prefix=(systemd-run --user --scope --quiet
    -p MemoryMax="$NQAF_MEMORY_MAX" -p MemorySwapMax=0 -p OOMPolicy=kill
    -p CPUQuota="$NQAF_CPU_QUOTA"
    "${limit_prefix[@]}")
else
  echo "Warning: systemd-run --user unavailable; agent and check run without memory or CPU caps" >&2
fi

# run_limited <cmd> [args...] — runs <cmd> in the foreground with inherited
# stdio and returns its exit status, inside a transient systemd user scope
# capped at NQAF_MEMORY_MAX with no swap and at NQAF_CPU_QUOTA, at low CPU and
# I/O priority.
run_limited() {
  "${limit_prefix[@]}" "$@"
}
