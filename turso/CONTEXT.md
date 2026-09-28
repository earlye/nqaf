# turso fork

The fork of turso (`earlye-forks/turso`) that nqaf tracks. It carries
the changes event-sorcerer needs from the engine.

## Language

**Orphan WAL**:
A `{db}-wal` file, valid on its own terms, that sits beside an **Empty db**.
_Avoid_: stale WAL, leftover WAL

**Empty db**:
A db file that counts as holding no database under the configured `EmptyDb` rule: `ZeroBytes`, `OneByte` or `InvalidHeader`, where each rule includes the ones before it.
_Avoid_: zero-page db (SQLite's term, which on unix also covers 1-byte files), wiped db

**Orphan WAL policy**:
What an open does with an **Orphan WAL**: `Replay` it (the upstream default) or `Discard` it.
_Avoid_: discard flag

**IO extension**:
A capability the fork adds to turso's `IO` trait beyond upstream, as a required method.
_Avoid_: IO patch, IO capability

## Relationships

- An **Orphan WAL** exists only relative to an **Empty db**. A WAL beside a non-empty db is never an orphan.
- The **Orphan WAL policy** `Discard` depends on the **IO extension** `sync_parent_dir`.

## Example dialogue

> **Dev:** "The db file is 4096 bytes of zeros with a WAL beside it. Is that an **Orphan WAL**?"
> **Domain expert:** "Only if the policy's **Empty db** rule is `InvalidHeader`. Under `ZeroBytes` the db isn't empty, so the WAL is replayed as usual."

## Flagged ambiguities

- "zero pages" in SQLite covers 0- and 1-byte files, because of a quirk in its unix VFS. Here, **Empty db** is always stated along with its `EmptyDb` rule.
