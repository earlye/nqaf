# turso: opt-in option to name the MVCC log by suffix and reach it through the IO

## Context

`earlye-forks/turso` is a fork of `tursodatabase/turso`. event-sorcerer
pins it in its `Cargo.lock` at
`4b59a37fe7713ef3ef6e8e0852c0ca57083de4e6`. At that rev, turso finds a
database's WAL through the `IO` the caller supplies, but finds its MVCC
logical log partly through `std::fs`, under a name that is not derived
the way the WAL's is.

Wanted: a `DatabaseOpts` option, **off by default** so upstream naming
and behaviour are unchanged, that makes the MVCC log a plain sidecar
like the WAL. When the option is on:

1. **Suffix naming.** The log is named `{name}-log`, suffixed onto the
   same `name` the WAL suffixes (`{name}-wal`, `lib.rs:1383-1387`).
   Today it is `db_path.with_extension("db-log")`
   (`storage/journal_mode.rs:61`, in `logical_log_exists`, and `:90`, in
   `open_mv_store`), which replaces the extension instead of appending
   to it. So `foo.sqlite` and `foo.db` both map to `foo.db-log` and
   collide, and `foo` maps to `foo.db-log` as well.
2. **Existence check through the IO.** `logical_log_exists`
   (`storage/journal_mode.rs:59-63`) runs through the supplied `IO`, not
   through `std::path::Path::exists` +
   `metadata().unwrap().len() > 0`. It is called on every open
   (`lib.rs:1725-1726`), and also on the `conn_raw_api` external-restore
   reload (`lib.rs:2100`). The `std::fs` version has two problems:
   - Under a non-filesystem IO (for example `MemoryIO`), it looks at an
     unrelated path on the real disk. If a stray file happens to be
     there, a WAL-mode open fails hard with
     `Corrupt("MVCC logical log file exists for database …, but database header indicates WAL mode…")`
     (`lib.rs:1893-1898`).
   - `metadata().unwrap()` can panic if the file disappears between
     `exists` and `metadata`.

The log itself is already opened through the IO:
`io.open_file(string_path, …)` at `storage/journal_mode.rs:95`. Only
its name and its existence check escape.

All turso paths are relative to `core/` at fork rev `4b59a37`.

### Known `std::fs` reach this issue does not address

Recorded so the conformance claim does not assert against it:

- **Canonicalised path for the MVCC store.** When MVCC is on, open
  passes `get_database_canonical_path()` to `open_mv_store`
  (`lib.rs:2024-2029`). That function calls `std::fs::canonicalize`,
  and falls back to the raw path if the call fails
  (`lib.rs:2045-2056`). This matters to item 1 above: on
  `PlatformIO`, the log name is derived from the canonical path, while
  the WAL name comes from the path as passed. The implementer should
  decide whether `{name}-log` under the option uses the same `name` the
  WAL uses (recommended, for sidecar parity), and state the choice in
  the prompt.
- **Process-wide `Database` registry.** The registry is keyed by
  `(dev, ino)` from `std::fs::metadata` (`io/get_file_id`,
  `io/mod.rs:91-99`). `lookup_in_registry` (`lib.rs:936-971`) is
  checked first in `open_file_with_flags_and_durable_storage`
  (`lib.rs:993-1004`). It returns the already-open `Database`, with
  the IO it was first opened with, and ignores the IO passed in.
  event-sorcerer accepts this outcome: two groups that share a name get
  one `Database`, its schema check says `Opened`, and its
  identity-mismatch guard fires, which is the correct refusal. So this
  stays as-is.

## Why event-sorcerer wants it (not blocking)

event-sorcerer's per-group storage is `storage = { io, name }`.
`name` is opaque and interpreted by the IO: a filesystem path for
`PlatformIO`, a map key for `MemoryIO`, a lookup key for an embedded
store. Its docs tell hosts that wiping a db means wiping its sidecars,
which only works if the sidecars are `{name}-*` inside the same IO.

The WAL already is. The MVCC log is not, and event-sorcerer only uses
MVCC once it moves to `BEGIN CONCURRENT` writers. So this option is a
**prerequisite for that later `BEGIN CONCURRENT` work**, and is **not**
needed for the single-db-per-group change.

## Proposed change

This is the shape of the `turso/prompts/feature-NNN.md` prompt.

- Add a `DatabaseOpts::with_mvcc_log_suffix_naming(bool)` option, with
  a field beside the existing `enable_*` flags (`lib.rs:224-238`,
  builders `:251-310`). The default is `false`. The exact name is open.
- Thread the option (or the derived log path) to both `with_extension`
  sites in `storage/journal_mode.rs` (`:61`, `:90`), and to both
  `logical_log_exists` callers (`lib.rs:1726`, `lib.rs:2100`).
- When the option is on, derive the log path as `format!("{name}-log")`.
  Check that it exists by opening it through the supplied `IO` without
  `Create`: `NotFound` means the log is absent, and otherwise
  `File::size()` (`io/mod.rs:197`) must be `> 0`. No `unwrap` on a race.
- When the option is off, behaviour and naming are byte-for-byte
  unchanged. That includes the `with_extension("db-log")` quirk, which
  other callers may rely on.
- Update the module doc comment in
  `mvcc/persistent_storage/logical_log.rs:9-10`, which names the log
  `.db-log`, to mention the option.
- Add a regression test in the fork's own test suite (nqaf convention:
  prompts carry their own regression test). Under the option, a
  `MemoryIO`-backed MVCC db creates `{name}-log` inside the IO and
  nothing on disk. Paths `foo.sqlite` and `foo.db` get distinct logs.
  A stray `foo.db-log` on disk does not make a `MemoryIO` WAL-mode open
  fail as `Corrupt`.

## Acceptance

A **turso-conformance claim** in event-sorcerer
(`/home/ec2-user/event-sorcerer/turso-conformance/tests/`, run with
`just conformance`), in addition to the fork-side regression test.
nqaf has no conformance convention of its own. event-sorcerer's
single-db issue already plans this claim as its Acceptance 7:

- The option is on and the db uses `MemoryIO` with MVCC on. The MVCC
  log is `{name}-log`, it is opened and existence-checked through the
  IO, and nothing appears on disk.
- **Control:** the option is off and the db uses `PlatformIO`. The log
  is at `with_extension("db-log")`, and `foo.sqlite` and `foo.db`
  share it. This keeps the option-on half falsifiable.
- It does not assert against the `canonicalize` or `(dev, ino)`
  registry reach listed above.
- It runs against the fork rev event-sorcerer's workspace `Cargo.lock`
  pins, per the crate's smoke tier.

## Landing it through nqaf

This issue shares its setup with
`issues/issue-01a0e610-b729-7cc3-97e6-e8b99cb808f0-turso-discard-orphan-wal.md`.
nqaf has no `turso/` fork-dir yet, so this needs the `turso/`
`upstream.txt`, `fork.txt` and `feature-000.md` bootstrap described
there. That issue is blocking and this one is not, so number the
orphan-WAL prompt first.

## Relevant files

Fork `earlye-forks/turso` @ `4b59a37`, `core/`:

- `storage/journal_mode.rs:59-63`: `logical_log_exists`, which uses
  `std::fs` and `unwrap`.
- `storage/journal_mode.rs:61,90`: `with_extension("db-log")`
  naming.
- `storage/journal_mode.rs:95`: the log opened through `io.open_file`,
  which is already on the IO.
- `lib.rs:1725-1726`: `logical_log_exists` on every open.
- `lib.rs:1893-1898`: `Corrupt` when a log exists in WAL mode.
- `lib.rs:2100`: second `logical_log_exists` caller, in the
  `conn_raw_api` external-restore reload.
- `lib.rs:2024-2029,2045-2056`: the canonical path passed to
  `open_mv_store`, and `std::fs::canonicalize`. Known, not addressed.
- `io/mod.rs:91-99`, `lib.rs:936-971,993-1004`: the `(dev, ino)`
  registry, which returns an open `Database` with its original IO.
  Known, not addressed.
- `lib.rs:1383-1387`: `{path}-wal`, the suffix naming to match.
- `mvcc/persistent_storage/logical_log.rs:9-10`: doc comment naming
  `.db-log`.

## Related

- event-sorcerer
  `issues/issue-01a0c5c3-e521-73b1-a208-57373c478240-single-turso-db-per-group.md`.
  Its "Out of scope / follow-ups" bullet on `BEGIN CONCURRENT` writers
  names this option as a prerequisite. The "Sidecar reach" bullet in
  its Open path records the decision, and its Acceptance 7 is the
  conformance claim. It does not block that issue.
