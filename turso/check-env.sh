# shellcheck shell=bash
# Sourced by turso/check from turso/work. Fills host gaps that `make test`
# assumes CI provides, using only user-level, cached installs.

PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin"

# pyo3-ffi (abi3-py310) needs Python >=3.10; the host python3 is 3.9.
PYO3_PYTHON="$(uv python find '>=3.10' 2>/dev/null || { uv python install 3.12 >&2 && uv python find 3.12; })"
export PYO3_PYTHON
echo "PYO3_PYTHON=$PYO3_PYTHON"

# One-shot check runs gain nothing from incremental caches, which grew to 13G
# in target/debug/incremental and filled the disk.
export CARGO_INCREMENTAL=0

# The prebuilt sqlite-tools CLI that scripts/install-sqlite3.sh downloads needs
# GLIBC_2.38, and test-sqlite3's `--features sqlite3` run links -lsqlite3, which
# needs sqlite-devel. Build the pinned version from the amalgamation instead:
# the CLI (with the sqlite-tools CLI's usual options) pre-seeds .sqlite3/sqlite3
# so the install script skips the download; a static PIC libsqlite3.a goes on
# LIBRARY_PATH so the test binary needs no runtime library path.
sqlite_ver="$(sed -n 's/^SQLITE_VERSION="${SQLITE_VERSION:-\([0-9]*\)}"$/\1/p' scripts/install-sqlite3.sh)"
sqlite_year="$(sed -n 's/^SQLITE_YEAR="${SQLITE_YEAR:-\([0-9]*\)}"$/\1/p' scripts/install-sqlite3.sh)"
sqlite_dir="$HOME/.cache/nqaf/sqlite-$sqlite_ver"
if [ ! -x "$sqlite_dir/sqlite3" ] || [ ! -f "$sqlite_dir/lib/libsqlite3.a" ]; then
  echo "Building sqlite $sqlite_ver into $sqlite_dir"
  src="$(mktemp -d)"
  curl -fsSL -o "$src/a.zip" "https://sqlite.org/$sqlite_year/sqlite-amalgamation-$sqlite_ver.zip"
  unzip -q -j "$src/a.zip" -d "$src"
  opts="-O2 -fPIC -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_FTS4
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY
    -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_STMTVTAB
    -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_ENABLE_OFFSET_SQL_FUNC
    -DSQLITE_ENABLE_EXPLAIN_COMMENTS -DSQLITE_ENABLE_UNKNOWN_SQL_FUNCTION
    -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_COLUMN_METADATA"
  # shellcheck disable=SC2086
  gcc $opts -c -o "$src/sqlite3.o" "$src/sqlite3.c"
  # shellcheck disable=SC2086
  gcc $opts -o "$src/sqlite3" "$src/shell.c" "$src/sqlite3.o" -lm -ldl -lpthread
  ar rcs "$src/libsqlite3.a" "$src/sqlite3.o"
  mkdir -p "$sqlite_dir/lib"
  mv "$src/libsqlite3.a" "$sqlite_dir/lib/"
  mv "$src/sqlite3" "$sqlite_dir/"
  rm -rf "$src"
fi
mkdir -p .sqlite3
cmp -s "$sqlite_dir/sqlite3" .sqlite3/sqlite3 || cp -f "$sqlite_dir/sqlite3" .sqlite3/sqlite3
.sqlite3/sqlite3 --version
export LIBRARY_PATH="$sqlite_dir/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
# testing/cli_tests clones testing.db with a bare `sqlite3`; the host has none.
PATH="$sqlite_dir:$PATH"

# yarn (test-sqltest-js) comes from corepack; the repo pins it via yarnPath.
command -v yarn >/dev/null || corepack enable --install-directory "$HOME/.local/bin"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
