# turso: stop `op_variable` from cloning bound parameters

## Context

`earlye-forks/turso` is a fork of `tursodatabase/turso`. event-sorcerer
pins it at rev `4b59a37`. This candidate for a fork patch was split out
of event-sorcerer issue `31a16f9d4ca6` (zero-copy-event-payload-path),
with the user's approval. event-sorcerer-secretary forwarded it here.

At that rev, `op_variable` copies every bound parameter in full before
`make_record` serializes it again:

- `op_variable` (`core/vdbe/execute.rs:13285-13295`) does
  `registers[dest].set_value(state.get_parameter(index))`.
- `get_parameter` (`core/vdbe/mod.rs:917-920`) is
  `self.parameters.get(i).cloned()`. Each bound blob is therefore copied
  once here, before the record and page copies happen.

Wanted: move or borrow the parameter into the register instead of
cloning it. That would save one full copy of each bound value for every
caller.

## Alternative that was considered

A borrowing bind API would save less. `ValueRef<'a>` already exists
(`core/types.rs:264-279`), but `bind_at` takes an owned `Value`. Making
`bind_at` borrow would only save the caller's owned `Vec`, because the
record and page copies happen regardless. The `op_variable` change is
the better target.

## Conformance claim

event-sorcerer's `standards.md` says that an NQAF ask should come with
a turso-conformance claim in event-sorcerer's `turso-conformance` crate.
That claim belongs in the event-sorcerer repo, not here.

## Relevant files (turso at 4b59a37)

- `core/vdbe/execute.rs:13285-13295`: `op_variable`, where the cloned
  value is stored in the register
- `core/vdbe/mod.rs:917-920`: `get_parameter`, which does the clone
- `core/types.rs:264-279`: `ValueRef<'a>`
- `bind_at`: takes an owned `Value`
