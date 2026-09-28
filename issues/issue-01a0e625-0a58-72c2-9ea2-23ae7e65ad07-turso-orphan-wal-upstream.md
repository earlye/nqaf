# turso: consider taking the orphan-WAL discard fix upstream

## Context

This is a deferred decision. On 2026-09-28, while grilling
`issues/issue-01a0e610-b729-7cc3-97e6-e8b99cb808f0-turso-discard-orphan-wal.md`,
we decided to keep the orphan-WAL discard as an opt-in option that
lives only in the fork: a `turso/prompts/feature-NNN.md` prompt applied
to `earlye-forks/turso`, off by default. We will not propose it to
`tursodatabase/turso` for now.

Reasons to revisit:

- SQLite always deletes an orphan WAL that sits beside a zero-page db.
  It does this even on a read-only open of a 0-byte db. This was
  observed on SQLite 3.40.0 and 3.46.0; the details are in that
  issue's "What SQLite does" section. turso aims to be compatible with
  SQLite, so upstream would probably accept this as a bug fix that is
  on by default.
- Once upstream has the fix, the nqaf prompt's check for whether the
  fix is already present makes the prompt a no-op. The opt-in flag and
  the fork-side upkeep can then be retired.

Until then, the flag's name and shape should allow it to default to
`true` later without surprising callers, as
`with_discard_orphan_wal(bool)` does.

If this goes upstream, the upstream issue can reuse Reproduction steps
1–5 from the parent issue as its repro. Any GitHub post must carry the
🤖 attribution prefix.

## Blocked by

- `issues/issue-01a0e610-b729-7cc3-97e6-e8b99cb808f0-turso-discard-orphan-wal.md`
  must land in the fork first, since its patch is what would be
  proposed upstream.
