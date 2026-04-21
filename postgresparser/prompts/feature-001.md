# Fix: JSONB operators ?, ?|, ?& not valid in CHECK constraint expressions

## Problem

The ANTLR grammar in this repo fails to parse the PostgreSQL JSONB containment
operators `?`, `?|`, and `?&` when they appear inside DDL `CHECK` constraints.
The parser silently drops all SQL statements that follow the failing constraint,
which makes this a data-loss bug for callers processing DDL files.

Example that fails to parse correctly:

```sql
CREATE TABLE example (
    data jsonb,
    CONSTRAINT chk_has_key CHECK (data ? 'some_key')
);
```

## Fix

Fix this at the ANTLR grammar level — do NOT add pre- or post-processing passes
over the SQL string. A character-by-character scan duplicates work the lexer
already does and adds a maintenance burden every time the grammar evolves.

Extend the ANTLR grammar so that `?`, `?|`, and `?&` are recognised as binary
operators inside `a_expr`, and ensure that `columnConstraint` and
`tableConstraint` rules accept them when they appear in CHECK expressions.

Concretely:
- Locate the grammar file(s) that define `a_expr`, `columnConstraint`, and
  `tableConstraint` (likely under `grammar/` or `src/`).
- Add lexer tokens for `?`, `?|`, and `?&` if they don't already exist. Be
  careful: `?` may already be used as an ANTLR meta-character in other rules —
  add it as a named token (e.g., `QUESTION_MARK`, `QUESTION_OR`, `QUESTION_AND`)
  and reference it by token name everywhere.
- Add production alternatives in `a_expr` that use these tokens as infix
  operators, following the same pattern as existing infix operator rules.
- Verify that the fix doesn't break existing tests. If there's a test suite,
  run it. If not, note what tests would be needed.
- Add a regression test (or test case in whatever format the project uses) that
  parses the example above and asserts it produces a valid parse tree.

## Why this matters

Silent statement-dropping means callers can't distinguish "parsed successfully
with zero statements" from "parsing stopped mid-file". Any tool that ingests
PostgreSQL DDL containing JSONB CHECK constraints will silently lose schema
information.
