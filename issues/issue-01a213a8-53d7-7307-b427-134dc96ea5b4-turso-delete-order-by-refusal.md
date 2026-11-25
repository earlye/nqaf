# turso: `DELETE ... ORDER BY ... LIMIT` must be refused with an error that names ORDER BY, or actually supported

## Context

event-sorcerer is bumping `turso_core` from fork rev `4b59a37` to
`066f662`, the current HEAD of `earlye-forks/turso`. Its conformance
test `claim_4b_direct_form_is_refused_rather_than_silently_unordered`
passes at `4b59a37` and fails at `066f662`. Early decided not to loosen
the test, so the fork has to change. The event-sorcerer session that is
doing the bump (`earlye/1f66d8740ac4/update-turso-to-latest-fork`)
requested this issue.

event-sorcerer uses a bounded, ordered `DELETE` as a TTL eviction chunk.
Every cluster member runs the same chunk at the same log index, so every
member must delete the same rows. The test runs:

```sql
DELETE FROM events WHERE delete_after < 500 ORDER BY delete_after, id LIMIT 3
```

The test passes in either of these cases:

1. The statement runs and deletes exactly the correctly ordered first
   chunk.
2. The statement returns an error whose `format!("{err:?}")` contains
   `"ORDER BY"`, and no rows are deleted.

Silently deleting an unordered set of rows is what the test exists to
rule out. The "names ORDER BY" check makes sure that an unrelated
failure, such as a statement that is broken for some other reason,
can't pass as the refusal.

## What changed between the two revs

- **At `4b59a37`:** the parser accepted `order_by` and `limit` on
  `Stmt::Delete` (`sqlite/parser/src/parser.rs:4639-4659`). The
  translator then refused the statement unconditionally
  (`core/translate/mod.rs:287-289`) with:
  `ParseError("ORDER BY clause is not supported in DELETE")`
- **At `066f662`:** the parser rejects the statement earlier, at the
  ORDER token:
  `LexerError(ParseUnexpectedToken { parsed_offset: SourceSpan { offset: SourceOffset(44), length: 1 }, got: TK_ORDER, expected: [TK_SEMI], token_text: "ORDER", offset: 44, expected_display: ";" })`

The statement is still refused, but the error no longer says why, so
the test fails at its `message.contains("ORDER BY")` assertion (around
line 450).

## Root cause hypothesis (unconfirmed)

The new parser seems to have dropped the `ORDER BY`/`LIMIT` grammar on
`DELETE`. That probably came in with the upstream re-mirror in fork
commit `1ccaf5c09`, which was carried onto upstream `8cc059bd9`.

## Decision

Option (a), decided 2026-11-25. Option (b) is tracked separately in
`issues/issue-01a213d0-9ec4-7385-9962-480591c54170-turso-support-delete-order-by-limit.md`.

The fix is a new prompt, `turso/prompts/feature-006.md`, applied with the
usual scripts:

- Refuse in the parser, so that nothing can run before the error.
- The error text is `ORDER BY clause is not supported in DELETE`, which
  matches the message at `4b59a37`.
- `DELETE ... LIMIT n` without ORDER BY is also refused, with an error
  that names LIMIT. It has the same unordered-delete hazard.
- Add a turso_core unit test for both cases, and add it to `turso/check`.

## Options considered

Either option satisfies event-sorcerer:

- **(a) Refuse with an error that names ORDER BY.** For example, restore
  the parser grammar and keep the translator's guard, or make the parser
  report an error that mentions ORDER BY when it sees ORDER after a
  DELETE. Nothing may be deleted before the error is returned.
- **(b) Actually support `DELETE ... ORDER BY ... LIMIT`.** The statement
  must delete exactly the first rows in `ORDER BY` order. Ignoring the
  ORDER BY and deleting rows in scan order fails the test.

## How to reproduce

The test was copied from event-sorcerer's
`turso-conformance/tests/claim_bounded_eviction_chunk.rs` into this repo
at `turso/conformance/claim-4b-delete-order-by/`. The copy is a
standalone crate with an empty `[workspace]`, and its `Cargo.lock` pins
the fork at `066f662`. `src/lib.rs` has already been adapted to the
0.8.0 API
(`Database::open(io, path, OpenOptions::new(Arc::new(SqliteDialect)))`).

```sh
cargo test \
  --manifest-path turso/conformance/claim-4b-delete-order-by/Cargo.toml \
  --target-dir /tmp/claim-4b-target \
  --test claim_bounded_eviction_chunk claim_4b
```

To test a fixed fork, point the `turso_core` dependency at the fix
(with a `[patch]` section or a path dependency). The module doc comment
at the top of the test file explains the claim, and the claim 4b test is
at about lines 380–460.

## Relevant files

- `turso/conformance/claim-4b-delete-order-by/tests/claim_bounded_eviction_chunk.rs`:
  the test
- turso `core/translate/mod.rs:287-289` (at `4b59a37`): the old
  translator guard, whose error named ORDER BY
- turso `sqlite/parser/src/parser.rs:4639-4659` (at `4b59a37`): the old
  parser grammar for `order_by` and `limit` on `Stmt::Delete`
- turso fork commit `1ccaf5c09`: the suspected re-mirror that dropped
  the grammar

## Grill Log

### 2026-11-25

- Q: Refuse with an error naming ORDER BY (a), or support the statement (b)?
  Defaults proposed for (a): refuse in the parser, reuse the old message,
  also refuse `DELETE ... LIMIT` with an error naming LIMIT, add a unit test
  to `turso/check`. — A: (a) for now, with the proposed defaults. Track (b)
  as its own issue (`turso-support-delete-order-by-limit`).
