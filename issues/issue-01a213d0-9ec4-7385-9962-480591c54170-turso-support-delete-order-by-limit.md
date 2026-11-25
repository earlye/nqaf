# turso: support `DELETE ... ORDER BY ... LIMIT`

## Context

Follow-up to `turso-delete-order-by-refusal` (id `134dc96ea5b4`). That
issue had two options for event-sorcerer's conformance test
`claim_4b_direct_form_is_refused_rather_than_silently_unordered`:

- (a) refuse `DELETE ... ORDER BY ... LIMIT` with an error that names
  ORDER BY, and delete nothing;
- (b) actually support the statement.

On 2026-11-25 Early chose (a) for now, and asked for (b) to be tracked
separately. This is (b).

The goal is SQLite's `SQLITE_ENABLE_UPDATE_DELETE_LIMIT` behavior: the
statement deletes exactly the first rows in `ORDER BY` order, up to
`LIMIT` (and `OFFSET`, if given). Ignoring the ORDER BY and deleting rows
in scan order is wrong. event-sorcerer uses a bounded, ordered `DELETE`
as a TTL eviction chunk that every cluster member runs at the same log
index, so every member must delete the same rows.

event-sorcerer's claim 4b test accepts either behavior, so it doesn't
need to change when this lands. The test is copied at
`turso/conformance/claim-4b-delete-order-by/`.

## Scope

This needs AST, parser, and translator changes in the fork, and it
replaces the refusal that option (a) adds. At fork rev `4b59a37`, the
parser accepted `order_by` and `limit` on `Stmt::Delete`
(`sqlite/parser/src/parser.rs:4639-4659`) and the translator refused it
(`core/translate/mod.rs:287-289`). At `066f662` (after the upstream
re-mirror in fork commit `1ccaf5c09`) the parser no longer accepts the
grammar at all.

## Blocked by

- `turso-delete-order-by-refusal` (`134dc96ea5b4`): this issue replaces
  the refusal that one adds.
