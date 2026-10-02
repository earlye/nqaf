# turso: opt-in option to discard an orphan WAL beside an empty db

## Context

`earlye-forks/turso` (fork of `tursodatabase/turso`, consumed by
event-sorcerer as a git dependency, pinned in its `Cargo.lock` at
`4b59a37fe7713ef3ef6e8e0852c0ca57083de4e6`) replays a leftover
`{name}-wal` even when the db file it belongs to is absent or 0 bytes.
The old database then comes back on the next write that allocates page
1, with every table and row intact and `PRAGMA integrity_check` = `ok`.

Wanted: a `DatabaseOpts` orphan-WAL policy, defaulting to `Replay` so
upstream behaviour is unchanged. Under `Discard`, open throws away
`{name}-wal` instead of replaying it when the db file counts as an
**Empty db** (see `turso/CONTEXT.md`). SQLite does something similar.
The full design is under "Proposed change". The decisions and the
rejected alternatives are in the Grill Log.

All turso paths below are relative to `core/` at fork rev `4b59a37`.

### What turso does today

- **Open always loads `{path}-wal` if present.** The WAL path is
  `format!("{path}-wal")` (`lib.rs:1383-1387`). The `OpenWal` phase
  always opens and scans the shared WAL, then attaches it to the pager
  (`lib.rs:1957-2022`), via `WalFileShared::open_shared_if_exists_begin`
  (`storage/wal.rs:5634-5654`), which only special-cases a missing WAL
  under `ReadOnly`, and `BuildSharedWal::begin`
  (`storage/sqlite3_ondisk.rs:1459-1525`), which only special-cases a
  WAL shorter than its header.
- **Validation only checks the WAL against itself.** The header
  checksum and page size are checked (`storage/sqlite3_ondisk.rs:1713-1754`),
  and each frame's salts and cumulative checksum are checked
  (`storage/sqlite3_ondisk.rs:1809-1840`). Nothing compares the WAL
  against the db file, so a WAL that is consistent with itself is
  accepted beside any db.
- **A 0-byte db looks empty.** When `db_size == 0`, `Database::new`
  installs an in-memory default page 1 (`lib.rs:730-736`), and header
  reads return it while it is set (`storage/pager.rs:1809-1813`). The
  schema reads as empty, even though the WAL holds a full database.
- **The old db stays hidden only while that in-memory page 1 lasts.**
  If the first write transaction commits, the old tables stay hidden
  (see Reproduction, path B). But `allocate_page1`
  (`storage/pager.rs:5182-5257`) writes page 1 to the **db file**
  (`begin_write_btree_page`, `:5234`) and clears the in-memory page 1
  (`:5250`). It does this as soon as a write transaction starts
  allocating, whether or not that transaction commits. After
  `BEGIN; CREATE TABLE z(q); ROLLBACK;` the db file is 4096 bytes, it
  no longer counts as empty, and the WAL frames are visible: the old
  tables and all their rows come back permanently, and
  `integrity_check` is `ok`. A crash after page 1 is allocated should
  do the same, because it leaves the same file state. That crash case
  is inferred from the code, not reproduced.

### What SQLite does

`pagerOpenWalIfPresent` deletes the WAL when the db has zero pages, and
opens it only otherwise. The brief for this issue said so from memory.
This session then read the SQLite 3.46.0 amalgamation
(`libsqlite3-sys-0.30.1/sqlite3/sqlite3.c:60436-60464`, from the local
cargo registry):

```c
if( isWal ){
  Pgno nPage;
  rc = pagerPagecount(pPager, &nPage);
  if( rc ) return rc;
  if( nPage==0 ){
    rc = sqlite3OsDelete(pPager->pVfs, pPager->zWal, 0);
  }else{
    rc = sqlite3PagerOpenWal(pPager, 0);
  }
}
```

Observed on 2026-09-28 against SQLite 3.40.0 (system Python) and
3.46.0 (built from the amalgamation above). Both gave the same results.
The setup was a self-consistent WAL holding tables `old_t` and `old_u`,
with no `-shm`. The WAL check runs on the first read, not on open.

| db file | open mode | result |
|---|---|---|
| absent | read-write | 0-byte db created, WAL deleted, schema `[]` |
| 0 bytes | read-write | WAL deleted, schema `[]` |
| 1 byte | read-write | WAL deleted, schema `[]` |
| 0 bytes | read-only | WAL deleted, even though the open is read-only |
| absent | read-only | open fails with `CANTOPEN`, WAL untouched |
| 0 bytes, stale `-shm` present | read-write | WAL deleted, `-shm` kept |

The source agrees:

- `pagerOpenWalIfPresent` guards the delete only on `!tempFile`
  (`sqlite3.c:60441`). It does not check read-only state.
- `pagerPagecount` (`:60376`) rounds a partial page up (`:60402`). But
  the unix VFS reports a 1-byte file as 0 bytes (`unixFileSize`,
  `:42247`, Ticket #3260, an OS-X msdos workaround). So "zero pages"
  means 0 or 1 bytes on unix, and a 2-byte to page-size file counts as
  one page. That last case comes from reading the code, not a run.
- After a `BEGIN; CREATE TABLE z(q); ROLLBACK;` and a reopen, every
  read-write case still shows schema `[]`, and `integrity_check` is
  `ok`.

The script and case dirs were in this session's scratchpad
(`sqlite-orphan-wal/t.py`), which is not kept.

### Discard mechanics in turso (source reading, 2026-09-28)

These findings come from reading the fork at `4b59a37`. None of it has
been run. The decisions based on it are under "Proposed change".

- **`remove_file` does not work everywhere.** It is `std::fs::remove_file`
  in unix, io_uring, generic, windows and win_iocp, and a map removal in
  memory IO. But in the browser IO it does nothing and returns `Ok`
  (`bindings/javascript/src/browser.rs:155`). `File::truncate`
  (`io/mod.rs:198`) works on every backend and is Completion-based. It
  is truly async on io_uring, vfs and browser. Checkpoint `TRUNCATE`
  already resets a WAL this way, with a truncate to 0 followed by a sync
  (`storage/wal.rs:5084-5120`).
- **Legacy mode is safe across processes.** A non-`ReadOnly` open takes
  an exclusive fcntl lock on the db file.
- **Multiprocess mode is not safe by default.** When
  `enable_multiprocess_wal` is set and the IO supports it
  (`lib.rs:2541-2564`), the db is opened `NoLock` (`lib.rs:840-842`).
  The `{db}-tshm` authority decides between `Exclusive` and
  `MultiProcess` open mode with a try-lock on byte 0
  (`storage/shared_wal_coordination.rs:1057-1080`), and it is opened
  inside OpenWal (`lib.rs:1976`). If the WAL is truncated or removed
  while a peer is attached, the peer's committed data is lost or
  diverges. `db_size` is read in `Database::new` (`lib.rs:715`), which
  is earlier than OpenWal, so it has to be checked again before
  discarding.
- **The in-process registry is safe.** `DATABASE_MANAGER`
  (`lib.rs:551-588`) returns the existing `Database`, so OpenWal does
  not run again. The exception is `open_with_flags_bypass_registry*`
  (`lib.rs:1291,1325`).
- **After a power loss, a legitimate WAL can sit beside a 0-byte db.**
  `allocate_page1` writes page 1 to the db file and waits for that
  write, but does not fsync it (`storage/pager.rs:5232-5239`). WAL
  commits fsync only the WAL. So if power is lost after the first
  commit, the db can be 0 bytes while the WAL holds committed frames,
  and discarding the WAL would lose them. The page-1 durability
  requirement under "Proposed change" closes this gap.

### Why event-sorcerer needs it (blocking)

event-sorcerer's per-group open path decides `Created` or `Opened` from
whether its tables exist in `sqlite_schema`. With an orphan WAL beside
a wiped db file, the schema looks empty, so open says `Created` and
starts init. If anything then allocates page 1 without committing, such
as a rolled-back init or a crash, the wiped RAFT member's old db comes
back, including its old identity and vote. event-sorcerer's ADR 0007
(`docs/adr/0007-group-creation-requires-peer-agreement.md`) exists to
prevent exactly this: a damaged member is never recovered in place.
event-sorcerer will set `Discard { empty: ZeroBytes, read_only: Ignore }`
in its open path, and also
document that wiping a db means wiping its sidecars. Two alternatives
were rejected there:

- A size check at the SDK level: it misses the window where a crash
  follows page-1 allocation.
- Documentation only: it covers operators, not crashes.

## Proposed change

This is the shape of the `turso/prompts/feature-NNN.md` prompt. See
"Landing it through nqaf" below.

- Add `DatabaseOpts::with_orphan_wal_policy(OrphanWalPolicy)`, with a
  field beside the existing `enable_*` flags (`lib.rs:224-238`,
  builders `:251-310`):

  ```rust
  enum OrphanWalPolicy {
      Replay,                           // default; upstream behaviour
      Discard {                         // read-write opens discard the WAL
          empty: EmptyDb,
          read_only: ReadOnlyOrphanWal,
      },
  }
  enum EmptyDb { ZeroBytes, OneByte, InvalidHeader }
  enum ReadOnlyOrphanWal { Ignore, Replay }
  ```

  The default is `Replay`. A nested enum means combinations that make
  no sense can't be written. Read-write opens have no `Ignore` choice
  on purpose: keeping the old WAL file while writing new frames would
  mean resetting its header safely, and discarding the file avoids that.
- `empty` decides which db files count as empty. Each value includes
  the ones before it:
  - `ZeroBytes`: the file is absent or 0 bytes. This is exactly when
    `init_page_1` is installed (`lib.rs:730-736`).
  - `OneByte`: also a 1-byte file. This copies what SQLite's unix VFS
    does (see "What SQLite does").
  - `InvalidHeader`: also any file whose page 1 is not a valid header.
    That means it is shorter than 512 bytes (too short for a full page
    1), or the header fails a check: the magic string
    `"SQLite format 3\0"`, the page size (a power of two from 512 to
    32768, or 1), the payload fractions 64/32/32, the schema format
    (0-4), the text encoding (0-3), or the reserved bytes 72-91 being
    zero. 0 counts as valid for schema format and text encoding,
    because SQLite leaves them at 0 until the first table is created.
    An encrypted db never counts as having an invalid header, because
    its page 1 can't be checked without the key. Page 1 is the only page that
    identifies itself. Without it, nothing else in the file can be
    reached, so "zero valid pages" and "invalid page 1" are the same
    rule. On a read-write open, `InvalidHeader` **truncates both the
    db file and the WAL to 0** and fsyncs them. It truncates the db
    **whether or not a WAL exists**, so it deliberately wipes a corrupt
    db. Under `OneByte`, the 1-byte db is truncated to 0 the same way. The db is then an
    ordinary empty db (`init_page_1`), and the open succeeds. Either
    truncation order converges: a crash between the two leaves a state
    the next open finishes. On a `ReadOnly` open, a db with an invalid
    header **fails to open**, whatever `read_only` is set to, because
    read-only means no modifications.
    **`InvalidHeader` depends on page-1 durability** (see below). If
    page 1 is zeroed after a power loss and the WAL holds a good page 1,
    replaying the WAL could have recovered the db. The durability
    requirement applies under every `Discard`, so a zeroed page 1 can
    never hide committed frames. What remains is real corruption, and
    `InvalidHeader` deliberately wipes it.
- Under `Discard`, on a read-write open, when the db file counts as
  empty under `empty`, discard `{name}-wal` before the
  `OpenWal` scan instead of replaying it. Go through the supplied `IO`,
  not `std::fs`: event-sorcerer hosts may supply non-filesystem IOs.
  - **"Discard" means truncating the WAL to 0 and fsyncing it, not
    unlinking it.** `IO::remove_file` does nothing on the browser IO,
    while `File::truncate` works on every backend. Checkpoint
    `TRUNCATE` already resets a WAL this way
    (`storage/wal.rs:5084-5120`), and turso treats a 0-byte WAL as no
    WAL (`storage/sqlite3_ondisk.rs:1498`). The file stays in place,
    unlike SQLite, which deletes it. That difference can't be observed.
  - Check the `empty` rule again right before truncating, because
    `db_size` is read in `Database::new` (`lib.rs:715`), which runs
    before OpenWal.
  - **Legacy mode** needs no other check, because the exclusive lock on
    the db file already rules out other processes.
  - **Multiprocess mode** (`enable_multiprocess_wal`): discard only
    when the `.tshm` coordination authority, opened in OpenWal at
    `lib.rs:1976`, reports `Exclusive`, meaning no other process has
    the db open. If it reports `MultiProcess`, **fail the open with a
    clear error**. Replaying would bring back the hazard, and
    truncating would corrupt the other process's view.
- Under `Discard`, a `ReadOnly` open of an empty db follows
  `read_only`. `Ignore` doesn't scan or attach the WAL, and leaves the
  file. `Replay` does what upstream does today. **Read-only opens never
  modify anything**, so there is no `Delete`. SQLite does delete the
  WAL on a read-only open (see "What SQLite does"), and this is a
  deliberate difference from it. The next read-write open discards the
  WAL. event-sorcerer starts with
  `Discard { empty: ZeroBytes, read_only: Ignore }`. A wipe that deletes
  or truncates the db then reads as empty, and a zeroed or garbage db
  fails on its header instead of coming back as `Created` (ADR 0007).
  It switches only if it sees a compelling reason.
- **Page-1 durability under `Discard`.** Under any `Discard` value,
  `allocate_page1` fsyncs the db file after writing page 1, before the
  first WAL frame is written. It also fsyncs the parent directory
  whenever the open found an empty db, including a 0-byte file that
  already existed, because turso can't tell whether this open created
  the file. Without this, a power loss right
  after the db is created can leave a legitimate WAL of committed
  frames beside a db that is absent, 0 bytes, or has a zeroed page 1,
  and `Discard` would delete that WAL. The cost is one or two fsyncs
  per db creation.
- **The directory sync is a fork IO extension.** It is a new
  **required** method on the `IO` trait (`io/mod.rs:366`):
  `sync_parent_dir(&self, path: &str, c: Completion) -> Result<Completion>`.
  `File::sync` (`io/mod.rs:157`) already covers the db file. The
  method is required, so every IO, including out-of-tree ones like
  event-sorcerer's, has to decide what it means for them before it
  compiles.
  - unix, io_uring, generic-on-unix and `SparseLinuxIo` open the parent
    directory and fsync it.
  - memory and memory_yield are a no-op returning `Ok`. Nothing
    survives a crash there, so there is nothing to make durable.
  - windows and win_iocp are a no-op returning `Ok`. NTFS journals the
    file creation, and the db-file flush before the first WAL write
    commits that journal, which SQLite relies on too. FAT and exFAT
    are not covered.
  - `VfsMod`, whose C-ABI extension has no slot for this, and browser
    `Opfs` return `Unsupported`.
  - The simulator and test IOs get whichever behaviour fits them.
  - A read-write open with `Discard` of an **empty** db, where a db
    is about to be created, fails with a clear error when
    `sync_parent_dir` returns `Unsupported`. It never falls back to a
    weaker guarantee. An open of a non-empty db skips the check and
    pays no directory fsync.
- Under `Replay`, behaviour is byte-for-byte unchanged, including no
  extra fsyncs.
- Add a regression test in the fork's own test suite (nqaf convention:
  prompts carry their own regression test, as in
  `obscura/prompts/feature-010.md`), covering the matrix under
  "Acceptance".
- Copy `turso/docs/adr/0001-io-extensions-are-required-trait-methods.md`
  into the fork at `docs/adr/`. Prompts are self-contained, so the
  prompt carries the ADR text. The nqaf copy is the source of truth.
- `open_with_flags_bypass_registry*` (`lib.rs:1291,1325`) lets a second
  `Database` in the same process open the same file, and fcntl locks
  don't exclude the same process. **Under `Discard`, such opens fail
  with a clear error.** The consequence is that sync-engine users can't
  combine it with `Discard`, because the sync engine reopens the db
  this way.

## Reproduction

Tested empirically against `turso_core` at `4b59a37` with `PlatformIO`,
from a scratch binary (`turso_core = { git =
"https://github.com/earlye-forks/turso.git", rev =
"4b59a37fe7713ef3ef6e8e0852c0ca57083de4e6" }`, with its own empty
`[workspace]`).

1. **Build a db with data.** Open `g.db` in a fresh temp dir with
   `Database::open_file(io, path)`, then `connect()`. Run
   `CREATE TABLE old_t(x, b); CREATE TABLE old_u(z); CREATE TABLE old_v(w);`.
   Then 300 times, run
   `INSERT INTO old_t VALUES (i, randomblob(200)); INSERT INTO old_v VALUES (randomblob(300));`.
   While it is open, `g.db` is 4096 bytes and `g.db-wal` is 2966432
   bytes. Copy `g.db-wal` aside, then close the connection.
2. **Make the WAL an orphan.** Delete `g.db` and `g.db-wal`, then copy
   the saved WAL back as `g.db-wal`. The result is no db file beside a
   self-consistent 2966432-byte WAL.
3. **Reopen (A).** Open `g.db` with a new `PlatformIO`. Results:
   `SELECT name FROM sqlite_schema` returns `[]`, `SELECT * FROM old_t`
   fails with `no such table: old_t`, and the WAL is still 2966432
   bytes.
4. **Rollback path (R): this is the resurrection.** On that connection,
   run `BEGIN; CREATE TABLE z(q); ROLLBACK;`, which succeeds. `g.db` is
   now 4096 bytes. A **new** connection on the same `Database` sees
   `sqlite_schema` = `old_t, old_u, old_v`, and
   `SELECT count(*) FROM old_t` = 300.
5. **Reopen after R (R2).** Close, drop the `Database`, and open again
   with a fresh `PlatformIO`. The schema is `old_t, old_u, old_v`,
   `count(*) FROM old_t` = 300, and `PRAGMA integrity_check` = `ok`.
   The resurrection is permanent.
6. **Commit path (B), a separate run that skips step 4.** Right after
   step 3, run
   `CREATE TABLE IF NOT EXISTS new_t(y); INSERT INTO new_t VALUES (9); CREATE TABLE n2(a);`
   and then 100 inserts of `randomblob(500)` into `n2`. A second
   connection sees `new_t, n2` only, `old_t` is `no such table`, and
   `integrity_check` = `ok`. After closing and reopening (C), the schema
   is still `new_t, n2`, `new_t` = `[9]`, and `old_t` is still absent.
   After `PRAGMA wal_checkpoint(TRUNCATE)`, the db is 16 pages. So when
   the first write commits, the old data stays hidden.
7. **For contrast, the commit path after R.** Running step 6 after step
   4 instead gives schema `old_t, old_u, old_v, new_t, n2`. Both old and
   new data are live and `integrity_check` = `ok`. After checkpoint the
   db is 59 pages.

In short, whether the old db comes back depends on whether page 1 is
allocated before the first commit. Neither result is an error, and
`integrity_check` reports `ok` either way.

## Acceptance

There are two layers. nqaf has no conformance-claim convention of its
own; its prompts carry a regression test inside the fork.

### Fork-side regression test (carried in the prompt)

It covers every setting:

1. **`Replay` control:** the resurrection in Reproduction steps 4-5
   still happens, and no extra fsyncs are issued.
2. **`ZeroBytes`:** with an orphan WAL beside an absent db, or beside
   a 0-byte db, the schema is empty. After
   `BEGIN; CREATE TABLE z(q); ROLLBACK;` and a reopen, the db is still
   empty and `integrity_check` is `ok`. A 1-byte db is **not** treated
   as empty.
3. **`OneByte`:** the 1-byte case is treated as empty too.
4. **`InvalidHeader`, read-write:** with a 4096-byte zero db and a WAL,
   both files are truncated, and the open succeeds with an empty db.
5. **Negative control:** a valid db with its WAL is replayed as usual,
   under every `empty` rule.
6. **Read-only:** `Ignore` gives an empty schema, and the WAL's size
   and contents are unchanged. `Replay` matches upstream. With
   `InvalidHeader`, the open fails and no file is modified.
7. **Durability:** under `Discard`, a counting IO sees a db-file sync
   and a `sync_parent_dir` after `allocate_page1`, before the first
   WAL write. Copy the `SyncCountingIo` pattern in `vdbe/vacuum.rs`.
   Power loss itself is not simulated.
8. **Unsupported IO:** on an IO whose `sync_parent_dir` returns
   `Unsupported`, a read-write `Discard` open of an empty db fails at
   open, and a non-empty db opens normally.
9. **Multiprocess:** `Discard` fails at open when another process is
   attached (the `.tshm` authority reports `MultiProcess`).

### event-sorcerer turso-conformance claim

The claim goes in `/home/ec2-user/event-sorcerer/turso-conformance/tests/`,
one claim per file, run with `just conformance`. See event-sorcerer's
`standards.md` ("Unverified engine claims go in `turso-conformance`")
and ADR 0003. It covers only what event-sorcerer relies on:

- **`Discard { empty: ZeroBytes, read_only: Ignore }`:** an orphan WAL
  beside an absent db, and beside a 0-byte db, is discarded. The schema
  is empty. After `BEGIN; CREATE TABLE z(q); ROLLBACK;` and a reopen,
  the old tables stay absent and `integrity_check` is `ok`.
- **`Replay` control, which must show the hazard:** the same sequence
  brings the old db back. This records upstream behaviour and keeps the
  claim falsifiable, as the conformance crate requires of every claim.
- The claim runs against the fork rev that event-sorcerer's workspace
  `Cargo.lock` pins, per the crate's smoke tier. Landing this therefore
  also means bumping that pin to the fork commit that carries the
  patch.

## Landing it through nqaf

nqaf does not track turso yet. `turso/` so far holds only the grill's
docs (`CONTEXT.md`, `io-extensions.md` and `docs/adr/0001-*`), and the
fork at `4b59a37` is a plain upstream merge commit ("Merge 'core/mvcc:
add tests for speculative checkpoint root mappings…'") with no
nqaf-applied prompts. event-sorcerer's `standards.md` ("Vendored
dependency: Turso") already asks for this fork to be wired into nqaf.
This issue needs that first:

- `turso/upstream.txt` → `https://github.com/tursodatabase/turso`
- `turso/fork.txt` → `https://github.com/earlye-forks/turso`
- `turso/prompts/feature-000.md`: the usual bootstrap prompt that marks
  the fork's README as nqaf-tracked, as in
  `obscura/prompts/feature-000.md`.
- `turso/prompts/feature-NNN.md`: this fix, then `scripts/apply turso
  <branch>`. When it lands, update `turso/io-extensions.md` with the
  prompt name.

`scripts/re-apply` gates its merge on `make test`, and turso's `test`
target is a large suite (compat, sqlite3, shell, JS and CLI runners).
Expect that gate to be slow or noisy for this fork.

## Next steps

- [x] Run a real SQLite build against the same orphan-WAL setup. Done
  on 2026-09-28; the results are under "What SQLite does".
- [x] Wire `turso/` into nqaf (see "Landing it through nqaf").
- [x] Write the prompt, with its regression test
  (`turso/prompts/feature-001.md`).
- [x] Apply it. Done on 2026-09-29: `earlye-forks/turso` branch
  `earlye/e8b99cb808f0/turso-discard-orphan-wal`, PR
  https://github.com/earlye-forks/turso/pull/1, fix commit `190db39d3`.
  The agent reported that `turso_core --lib` passed 2132 and failed 0,
  and that the 11 new tests pass. Windows and wasm were not built.
- [ ] Merge the fork PR, then bump event-sorcerer's turso pin and add
  the conformance claim. That happens in the event-sorcerer session,
  which has the decisions.

## Relevant files

Fork `earlye-forks/turso` @ `4b59a37`, `core/`:

- `lib.rs:224-238,251-310`: `DatabaseOpts` and its `with_*` builders,
  where the option goes.
- `lib.rs:730-736`: in-memory default page 1 when `db_size == 0`.
- `lib.rs:1383-1387`: `{path}-wal` derivation.
- `lib.rs:1957-2022`: `OpenWal` phase, which always opens and scans
  the WAL.
- `storage/wal.rs:5634-5654`: `open_shared_if_exists_begin`.
- `storage/sqlite3_ondisk.rs:1459-1525`: `BuildSharedWal::begin`.
- `storage/sqlite3_ondisk.rs:1713-1754,1809-1840`: WAL-internal header
  and frame validation, the only checks made.
- `storage/pager.rs:1809-1813`: header reads served from the in-memory
  page 1.
- `storage/pager.rs:5182-5257`: `allocate_page1`, which writes page 1 to
  the db file.
- `io/mod.rs:157,198,366,374`: `File::sync`, `File::truncate`, the
  `IO` trait (where `sync_parent_dir` goes), and `IO::remove_file`
  (not used, since it does nothing on the browser IO).
- `lib.rs:715,1976,2541-2564`: where `db_size` is read, where the
  `.tshm` authority is opened, and the multiprocess-mode gate.
- `storage/shared_wal_coordination.rs:1057-1080`: the choice between
  `Exclusive` and `MultiProcess` open mode.
- `storage/wal.rs:5084-5120`: checkpoint `TRUNCATE`, the model for
  truncate plus sync.
- `vdbe/vacuum.rs` `SyncCountingIo`: the pattern for the durability
  test.
- `bindings/javascript/src/browser.rs:155`: the browser
  `remove_file` that does nothing.

nqaf:

- `turso/CONTEXT.md`: glossary (**Orphan WAL**, **Empty db**,
  **Orphan WAL policy**, **IO extension**).
- `turso/docs/adr/0001-io-extensions-are-required-trait-methods.md`.
- `turso/io-extensions.md`: the list of IO extensions.
- `issues/issue-01a0e625-0a58-72c2-9ea2-23ae7e65ad07-turso-orphan-wal-upstream.md`:
  deferred decision on proposing this upstream.

Elsewhere:

- `libsqlite3-sys-0.30.1/sqlite3/sqlite3.c:60436-60464` (SQLite 3.46.0):
  `pagerOpenWalIfPresent`.
- event-sorcerer `docs/adr/0007-group-creation-requires-peer-agreement.md`:
  no in-place recovery of a damaged member.
- event-sorcerer `standards.md`: "Patching forked dependencies", and
  "Unverified engine claims go in `turso-conformance`".

## Blocking

- event-sorcerer
  `issues/issue-01a0c5c3-e521-73b1-a208-57373c478240-single-turso-db-per-group.md`.
  Its Open path's "Orphan `-wal`" decision and its Acceptance 8 depend
  on this option. It lists this as **Blocked by**.

## Grill Log

### 2026-09-28

- Q: Should the fix be opt-in and fork-only, or should it also be
  proposed to upstream turso as a default-on SQLite-compat fix? — A:
  Fork-only for now. Revisiting upstream is tracked as a deferred
  decision in
  `issues/issue-01a0e625-0a58-72c2-9ea2-23ae7e65ad07-turso-orphan-wal-upstream.md`.
  Keep the flag's name and shape compatible with later defaulting to
  `true`.
- Q: When the option is on, what should a read-only open of a zero-page
  db with an orphan WAL do? The choices were: delete it, as SQLite
  does; ignore it (don't scan or attach it, and leave the file); or
  replay it, as today. — A: Make it configurable, with an enum holding
  all three choices.
- Q: Should the API be a bool plus an enum, or one nested enum? — A:
  One nested enum: `OrphanWalPolicy { Replay (default), Discard {
  read_only: ReadOnlyOrphanWal { Delete, Ignore, Replay } } }`, set
  with `with_orphan_wal_policy`. Read-write opens have no `Ignore`
  choice.
- Q: What counts as "zero pages"? The recommendation was absent or 0
  bytes, not SQLite's 1-byte quirk. The user suggested "zero valid
  pages" instead. — A: We went through the format. Only page 1
  identifies itself, through its 100-byte header, so "zero valid pages"
  means "invalid page 1". The risk is that a WAL beside a torn or
  zeroed page 1 may be the only way to recover the db. The decision is
  to make it configurable, with `Discard { empty: EmptyDb { ZeroBytes,
  OneByte, InvalidHeader }, .. }`, each value including the ones before
  it. `InvalidHeader` depends on the page-1 durability fix.
- Q: Under `Discard`, should page 1 be made durable, with an fsync of
  the db file and of the parent directory on create, before the first
  WAL frame? — A: Yes, under every `Discard` value. That makes the
  `InvalidHeader` dependency true by construction.
- Q: Directory sync isn't on `IO`. Should it be a provided method with
  an `Unsupported` default, a required method, or a second interface
  reached by a hop (COM `QueryInterface`-style, `fn
  query_interface(&self, iid) -> Option<..>`)? — A: A required method
  on `IO`. The behaviour is known for every in-tree impl, and a
  compile error forces out-of-tree IOs to decide. The hop pays off for
  a set of related capabilities behind one interface, or a set of
  unrelated ones behind many, and neither is expected. Treat it as a
  fork **IO extension**, track it as one, and revisit the hop design if
  the set of extensions grows.
- Q: Where do the ADR, the extension tracking and the glossary go? —
  A: Under a new `turso/` fork dir, which this work creates anyway:
  `turso/docs/adr/0001-io-extensions-are-required-trait-methods.md`,
  `turso/io-extensions.md` (the list of extensions) and
  `turso/CONTEXT.md`. ADRs are also copied into the fork
  (`github.com/earlye-forks/turso`) at `docs/adr/`. Prompts are
  self-contained, so the prompt that introduces an ADR's subject
  carries the ADR text for the fork. The nqaf copy is the source of
  truth.
- Q: How does `Discard` remove the WAL? — A: Truncate it to 0 and
  fsync it, rather than `remove_file`, which does nothing on the
  browser IO. Check the empty rule again right before truncating. In
  multiprocess mode, discard only when the `.tshm` authority reports
  `Exclusive`, and otherwise fail the open. Legacy mode needs no extra
  check. `ReadOnlyOrphanWal::Delete` truncates too, and fails loudly
  if the WAL can't be written.
- Q: After `InvalidHeader` discards the WAL, the db file is still
  garbage. Should the open fail, or should the db be reinitialised? —
  A: On a read-write open, truncate both the db file and the WAL, which
  leaves an empty db. On a read-only open, fail. Read-only means no
  modifications.
- Q: Given that read-only means no modifications, should
  `ReadOnlyOrphanWal::Delete` stay? — A: No. It was our proposal,
  copied from SQLite, and turso has never had it, so it goes:
  `ReadOnlyOrphanWal { Ignore, Replay }`. (The Q2 and Q3 entries above
  list `Delete`, which is what was believed at that point.)
- Q: Which `empty` rule should event-sorcerer use? — A: Start with
  `ZeroBytes`, and switch only for a compelling reason.
  `InvalidHeader` would reinitialise a damaged member, which would then
  look `Created`.
- Q: How should Acceptance be split now that the option has more
  settings? — A: The fork-side regression test covers the full matrix
  of settings, including durability (sync calls counted, power loss not
  simulated), unsupported IO and multiprocess. The event-sorcerer claim
  covers only `Discard { ZeroBytes, Ignore }` plus the `Replay` hazard
  control.

### 2026-09-29

These questions came up while the prompt was being written.

- Q: Should `InvalidHeader` also wipe a corrupt db that has no WAL beside
  it? — A: Yes. Whether a WAL happens to be present shouldn't decide
  whether a garbage db can be used. The rejected alternative was to
  reset only when an orphan WAL is present.
- Q: When should `Discard` check whether `sync_parent_dir` is
  supported? — A: Only on a read-write open of an empty db, which is
  the only time a db is about to be created. The rejected alternative
  was every `Discard` open, which costs a directory fsync per open.
- Q: Under `OneByte`, should a read-write open truncate the 1-byte db
  to 0? — A: Yes.
- An **orphan WAL** is a `-wal` of nonzero length. turso already treats
  a 0-byte WAL as no WAL.

### 2026-10-02

The apply run departed from the spec in these places. All were
approved and folded into the prompt.

- Schema format 0 and text encoding 0 count as a valid header,
  because SQLite leaves them at 0 until the first table exists.
- Db files shorter than 512 bytes count as an invalid header, not
  only those under 100 bytes.
- An encrypted db never counts as having an invalid header.
- The parent directory is fsynced on every read-write open that finds
  an empty db, not only when this open created the db file.
- Registry-bypassed opens fail under `Discard`, so the sync engine
  can't be combined with `Discard`.
