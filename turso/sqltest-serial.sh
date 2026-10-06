#!/bin/sh
# Stand-in for sqlite/conformance's TEST_RUNNER that runs one sqltest at a time.
# big.sqltest and big-mvcc.sqltest each write ~7G of WAL/DB/log into /tmp
# (tmpfs, charged to the check's 20G memory cap); at the default two jobs they
# overlap and the cap OOM-kills the run.
sub=$1; shift
[ "$sub" = run ] && set -- --jobs 1 "$@"
exec cargo run --manifest-path "$(dirname "$0")/work/testing/sqltest/Cargo.toml" \
  --bin sqltest -- "$sub" "$@"
