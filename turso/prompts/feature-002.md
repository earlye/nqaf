# Stop `op_variable` (and `bind_at`) from copying bound parameters

## Problem [feature-002]

Every bound parameter is copied in full before `MakeRecord` serializes it
into the record. For a prepared insert that is bound, stepped, reset and
bound again in a loop, a blob payload is copied three times per execution:

1. **At bind time.** `ProgramState::bind_at` (`core/vdbe/mod.rs` ~892-911):
   when the slot already holds a Text or Blob (it does after the first
   execution, because bindings survive `reset()`), it calls
   `existing.do_extend(&new)`. That copies the caller's bytes into the old
   buffer and then drops the caller's `Vec`.
2. **At `Variable`.** `op_variable` (`core/vdbe/execute.rs` ~13285-13295)
   does `registers[dest].set_value(state.get_parameter(index))`, and
   `get_parameter` (`core/vdbe/mod.rs` ~917-920) is
   `self.parameters.get(i).cloned()`.
3. **Into the record.** `make_record` serializes the register value into the
   record buffer. This copy is unavoidable and stays.

Remove copies 1 and 2, so that the record serialization is the only copy of
a bound Text or Blob payload.

Code locations are hints, relative to upstream rev `4b59a37`. Line numbers
have probably drifted; search by name.

### Facts the fix must respect

- `Value` (`core/types.rs` ~264-271) is
  `Null | Numeric | Text(Text) | Blob(Vec<u8>)`. `Text` holds a
  `Cow<'static, str>`. Nothing in `Value` is shared or refcounted.
- `Register` (`core/vdbe/mod.rs` ~254-260) is
  `Value(Value) | Aggregate(AggContext) | Record(ImmutableRecord)`.
  `Register::get_value(&self) -> &Value` (~1334-1344) already returns a
  reference into a non-`Value` variant (`Record` returns its payload), and
  `make_record` / `ImmutableRecord::from_registers` read registers only
  through `get_value()`.
- **Bindings persist across `Statement::reset()`.** `ProgramState::reset`
  never touches `parameters`; only `clear_bindings` clears them. Reprepare
  (`core/statement.rs` ~890-907) saves and restores them with `mem::take`,
  and `reset_for_subprogram_reuse` keeps them. A re-run without rebinding
  must see the same values.
- **One parameter can be read many times per execution.** The translator
  emits one `Insn::Variable` per occurrence (`?1 ... ?1` reads the slot
  twice), and the ~30 `translate_expr_no_constant_opt` call sites (INSERT,
  multi-row VALUES, UPDATE SET, ...) run `Variable` once per row. Trigger
  bodies read NEW/OLD values as parameters that are rebound for every row
  (`core/translate/trigger_exec.rs`, `core/vdbe/execute.rs` ~4725-4731).
- Some code mutates registers in place: `apply_affinity_char` in
  `op_make_record` can rewrite Text to a number, and there are a handful of
  `if let Register::Value(..)` / `&mut state.registers[..]` sites in
  `execute.rs` and `mod.rs`.

So a plain move of the value out of its slot is wrong: it breaks both
persistence across reset and repeated reads. Do not do that, and do not
add translator analysis to prove "read exactly once".

## Fix

Share the parameter value between its slot and the registers that read it.

- Store parameters as `Vec<Arc<Value>>` (or an equivalent that keeps
  `Null`/`Numeric` inline and puts only Text/Blob behind an `Arc`, if that
  is simpler or cheaper; pick one and say which in the commit message).
- Add a register variant that holds a shared value, e.g.
  `Register::Shared(Arc<Value>)`. `op_variable` stores a clone of the
  slot's `Arc` (a refcount bump, no payload copy). `get_value()` returns
  `&**arc` for it.
- `bind_at` moves the caller's `Value` into a fresh `Arc` in the slot
  instead of calling `do_extend`. If a register still holds the old `Arc`,
  it keeps the old value; that is correct, and needs no unsafe code.
  `clear_bindings` and reprepare keep working on the new slot type.
- Every place that mutates a register in place must first turn a shared
  register into an owned `Register::Value` (e.g. with
  `Arc::unwrap_or_clone`), so that it never mutates the parameter slot.
  Copying at that point is fine; it only happens where the old code would
  have mutated a copy anyway.
- Audit every read-side pattern match on `Register::Value(Value::Text ..)`,
  `Register::Value(Value::Blob ..)`, `Register::Value(v)` and similar, in
  `core/vdbe/execute.rs`, `core/vdbe/mod.rs`, `core/storage/btree.rs`,
  `core/index_method/fts.rs`, `core/incremental/expr_compiler.rs` and
  anywhere else a search turns up. A missed match would make a shared
  register silently fall through to the wrong arm (for example, treat a
  Text value as not-text). Rewrite such matches to go through
  `get_value()` rather than adding a `Shared` arm to each one, where that
  keeps the code as clear.
- Anything that clones a whole `Register` (it derives `Clone` and
  `PartialEq`) should keep working; cloning a shared register clones the
  `Arc`. `PartialEq` must compare by value, so a shared register equals an
  owned register that holds an equal value.

Do not change `Value`'s public shape, the public `Statement::bind_at`
signature, or the record format. Do not make `bind_at` borrow
(`ValueRef`): that saves less, because the record copy happens anyway.

Optional, only if it falls out naturally: the trigger path at
`core/vdbe/execute.rs` ~4725-4731 clones each parent register into the
child program's parameters; it may pass the value along without a payload
copy. Skip it if it complicates the change.

## Regression tests

Add tests in `core` as `#[cfg(test)] mod param_sharing_tests;` in
`core/lib.rs` (keep that module name: nqaf's `turso/check` runs it by
name), using `turso_core::Statement` directly, because the SDK
layers convert values:

1. **Variable does not copy.** Prepare `SELECT ?1, ?1`. Build
   `Value::Blob(vec![7; 1 << 20])`, record the `Vec`'s `as_ptr()`, and bind
   it. Step, and assert that both result columns are `Value::Blob` with that
   same pointer and the same bytes. (This fails today because of the clone.)
2. **Persistence across reset.** `reset()`, step again without rebinding,
   and assert the same bytes and pointer.
3. **Rebind moves.** Rebind slot 1 with a new blob `Vec`, record its
   pointer, step, and assert the new pointer and bytes. (This fails today
   because of `do_extend`.)
4. **Text too.** Repeat 1-3 for a large `Text` value built from an owned
   `String`.
5. **In-place mutation does not leak into the slot.** With
   `CREATE TABLE t(n INTEGER, s)` (`s` has no affinity), prepare
   `INSERT INTO t VALUES (?1, ?1)`, bind the text `'42'`, step, `reset()`
   and step again without rebinding. `SELECT typeof(n), n, typeof(s), s
   FROM t` returns `integer, 42, text, '42'` for both rows: the numeric
   affinity applied to `n` changed neither `s` nor the parameter seen by
   the second execution.
6. **`clear_bindings`** after reset makes the parameter read as NULL.
7. **Insert round-trip.** Bind a 1 MB blob into
   `INSERT INTO t VALUES (?1)`, reset and rebind several times with
   different blobs, then read all rows back and compare bytes.

## Constraints

- Keep the diff focused on this change. Follow turso's existing code style,
  error handling and naming. No unrelated refactors.
- Do not add unsafe code for this.
- Run `cargo fmt`, `cargo clippy -p turso_core`, the new tests, and the
  existing `turso_core` lib tests that exercise statements, triggers,
  VACUUM and the VDBE (`cargo test -p turso_core --lib`). Also
  `cargo check` every crate that matches on `Register` variants, if any
  outside `core` do. Do not run the full `make test`.

## Update README

Under "Fork Features" in the "About This Fork" section of `README.md`
(added by feature-000 and feature-001; create the subsection if it is
missing), add a bullet: bound Text and Blob parameters are shared with the
registers that read them instead of copied, so binding and reading a
parameter no longer copies its payload. The record serialization is the
only copy.
