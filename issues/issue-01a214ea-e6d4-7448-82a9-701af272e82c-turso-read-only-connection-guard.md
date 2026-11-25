# turso: a cheap way to make a connection refuse writes while it serves reads

## Context

event-sorcerer pins `earlye-forks/turso` at `ff6103c3`. It supplies its
own IO: `MemoryIO` in tests and `PlatformIO` in hosts. The
event-sorcerer session `earlye/57373c478240/single-turso-db-per-group`
requested this issue.

event-sorcerer PR #23 (single-turso-db-per-group, merged) gives each
raft group one turso database, with one shared connection behind a
handle. Writes go through transaction guards (`Tx`, `Savepoint`), and
reads go through a `Read` guard. All three guards expose the same
underlying connection. So code that writes through `Read` compiles and
runs in autocommit, outside any transaction, and nothing stops it. Only
a doc comment forbids it. Nothing does this today, but a future caller
could, and a crash part-way through such a write would leave partial
data. The PR's self-review raised this, and Early would rather have
turso enforce the rule than rely on the doc comment.

Wanted: while a `Read` guard is held, any write on that connection
returns an error. Switching between read and write must be cheap,
because it happens on every guard hand-off.

## Options (to be decided in the grill)

1. **`PRAGMA query_only`**, as in SQLite. It is set per connection: turn
   it on when handing out `Read`, and off for `Tx`. **Check first**
   whether turso at `ff6103c3` already honours it. If it does, no fork
   change is needed, and event-sorcerer can adopt it directly. The check
   has not been done yet.
2. **A read-only `Connection`** that can be opened on the same
   `Database` alongside the read-write one (a per-connection read-only
   flag), so that `Read` can use that connection.

Whichever option is chosen, a test should show that a write through the
read-only path returns an error and changes nothing, under both
`MemoryIO` and `PlatformIO`.

## Finding: turso at `ff6103c3` already honours `PRAGMA query_only`

Checked by reading the source on 2026-11-25. Nothing was built or run.

- **The flag is per connection.** It is `Connection.query_only: AtomicBool`
  (`core/connection.rs:436`), it starts as false
  (`core/database.rs:2892`), and `set_query_only` is public on
  `turso_core::Connection` (`core/connection.rs:3925-3931`).
  `set_query_only` also forces cached prepared statements to be prepared
  again, so a statement that was prepared before the flag was set is
  still refused.
- **The pragma turns it on and off.** `PRAGMA query_only = 1` turns it
  on, `= 0` turns it off, and `PRAGMA query_only` with no value reads it
  (`core/translate/pragma.rs:1576-1611`).
- **Writes are refused when the statement is compiled.** INSERT, UPDATE,
  DELETE, all DDL, ANALYZE and OPTIMIZE fail with "Cannot execute write
  statement in query_only mode" (`core/translate/mod.rs:164-196`).
  VACUUM, REINDEX and writing pragmas are refused too.
- **Existing upstream tests cover it:**
  `bindings/rust/tests/integration_tests.rs:1082`,
  `tests/integration/reindex.rs:103-106`, and
  `tests/integration/query_processing/test_vacuum.rs:715-732`.
- **It works with any IO.** The check is a flag on the connection and
  does no IO, so it works with `MemoryIO` too.
- **There is no other per-connection read-only mode.** `OpenFlags::ReadOnly`
  applies to the whole `Database`, so option 2 would need a fork change.

So option 1 needs no fork change. event-sorcerer can call
`set_query_only(true)` when it hands out `Read` and `set_query_only(false)`
for `Tx`, or keep a second connection from the same `Database` that
stays query-only.

Limits:

- This guards against mistakes, not against a hostile caller: any code
  that holds the connection can run `PRAGMA query_only = 0`. If that
  matters, a small fork change could add a "locked" bit that stops the
  pragma from turning the flag off.
- The check is made when the statement is compiled, against a list of
  statement types. No VDBE-level check backs it up.

If event-sorcerer adopts `query_only` as it is, this issue can be
resolved with no fork change. It should also add a turso-conformance
claim that pins this behaviour, so that a future upstream bump can't
drop it silently.

## Coordination

The event-sorcerer-secretary session tracks the event-sorcerer side,
which adopts whatever the fork provides. Tell it when this lands.
