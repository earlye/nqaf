# turso: opt-in option to discard an orphan WAL beside an empty db

## Context

`earlye-forks/turso` (fork of `tursodatabase/turso`, consumed by
event-sorcerer as a git dependency, pinned in its `Cargo.lock` at
`4b59a37fe7713ef3ef6e8e0852c0ca57083de4e6`) replays a leftover
`{name}-wal` even when the db file it belongs to is absent or 0 bytes.
The old database then comes back on the next write that allocates page
1, with every table and row intact and `PRAGMA integrity_check` = `ok`.

Wanted: a `DatabaseOpts` option, **off by default** so upstream behaviour
is unchanged, that makes open discard `{name}-wal` instead of replaying
it when the db file has zero pages. SQLite does this.

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

### Why event-sorcerer needs it (blocking)

event-sorcerer's per-group open path decides `Created` or `Opened` from
whether its tables exist in `sqlite_schema`. With an orphan WAL beside
a wiped db file, the schema looks empty, so open says `Created` and
starts init. If anything then allocates page 1 without committing, such
as a rolled-back init or a crash, the wiped RAFT member's old db comes
back, including its old identity and vote. event-sorcerer's ADR 0007
(`docs/adr/0007-group-creation-requires-peer-agreement.md`) exists to
prevent exactly this: a damaged member is never recovered in place.
event-sorcerer will turn the option on in its open path, and also
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
      Replay,                                    // default; upstream behaviour
      Discard { read_only: ReadOnlyOrphanWal },  // read-write opens delete the WAL
  }
  enum ReadOnlyOrphanWal { Delete, Ignore, Replay }
  ```

  The default is `Replay`. A nested enum means combinations that make
  no sense can't be written. Read-write opens have no `Ignore` choice
  on purpose: keeping the old WAL file while writing new frames would
  mean resetting its header safely, and deleting the file avoids that.
- Under `Discard`, on a read-write open, when the db file has zero pages (it did not
  exist, or `db_size == 0`, which is exactly when `init_page_1` is
  installed at `lib.rs:730-736`), discard `{name}-wal` before the
  `OpenWal` scan instead of replaying it. Go through the supplied `IO`,
  not `std::fs`: event-sorcerer hosts may supply non-filesystem IOs.
  `IO::remove_file` exists (`io/mod.rs:374`), and so does
  `File::truncate` (`io/mod.rs:198`). Which one matches SQLite's
  delete, and is safe beside the multiprocess-WAL/`.tshm` coordination
  path (`host_shared_wal`), is for the implementer to settle.
- Under `Discard`, a `ReadOnly` open of a zero-page db follows
  `read_only`. `Delete` removes the WAL, as SQLite does (see "What
  SQLite does"). `Ignore` doesn't scan or attach it, and leaves the
  file. `Replay` does what upstream does today. event-sorcerer is
  expected to use `Discard { read_only: Ignore }`.
- Under `Replay`, behaviour is byte-for-byte unchanged.
- Add a regression test in the fork's own test suite (nqaf convention:
  prompts carry their own regression test, as in
  `obscura/prompts/feature-010.md`), covering both option states as in
  Acceptance.

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

A **turso-conformance claim** in event-sorcerer
(`/home/ec2-user/event-sorcerer/turso-conformance/tests/`, one claim per
file, run with `just conformance`; see event-sorcerer's `standards.md`
"Unverified engine claims go in `turso-conformance`" and ADR 0003),
covering both option states. nqaf has no conformance-claim convention
of its own: its prompts carry a regression test inside the fork. So
this issue asks for both, the fork-side regression test (above) and the
event-sorcerer claim.

- **Option on:** a self-consistent `{name}-wal` beside an absent db,
  and beside a 0-byte db, is discarded on open. The schema is empty.
  After `BEGIN; CREATE TABLE z(q); ROLLBACK;` and then a reopen, the old
  tables stay absent and `integrity_check` is `ok`.
- **Option off (the control, which must show the hazard):** the same
  sequence brings the old db back, as in Reproduction steps 4-5. This
  records upstream behaviour and keeps the option-on half falsifiable,
  as event-sorcerer's conformance crate requires of every claim.
- The claim runs against the fork rev that event-sorcerer's workspace
  `Cargo.lock` pins, per the crate's smoke tier. Landing this therefore
  also means bumping that pin to the fork commit carrying the patch.

## Landing it through nqaf

nqaf does not track turso yet. There is no `turso/` fork-dir, and the
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
  <branch>`.

`scripts/re-apply` gates its merge on `make test`, and turso's `test`
target is a large suite (compat, sqlite3, shell, JS and CLI runners).
Expect that gate to be slow or noisy for this fork.

## Next steps

- [x] Run a real SQLite build against the same orphan-WAL setup. Done
  on 2026-09-28; the results are under "What SQLite does".
- [ ] Wire `turso/` into nqaf (see "Landing it through nqaf").
- [ ] Write the prompt, with its regression test.
- [ ] Apply it, bump event-sorcerer's turso pin, and add the
  conformance claim.

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
- `io/mod.rs:198,374`: `File::truncate`, `IO::remove_file`.

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
