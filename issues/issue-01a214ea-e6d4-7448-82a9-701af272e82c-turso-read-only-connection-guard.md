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

## Coordination

The event-sorcerer-secretary session tracks the event-sorcerer side,
which adopts whatever the fork provides. Tell it when this lands.
