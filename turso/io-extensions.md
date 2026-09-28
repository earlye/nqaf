# turso IO extensions

This is the list of capabilities the fork adds to turso's `IO` trait
(`core/io/mod.rs`) beyond upstream. Each one is a required trait method
(see `docs/adr/0001-io-extensions-are-required-trait-methods.md`).
Once this list reaches two or more entries, revisit that ADR's
decision against `query_interface`.

## `sync_parent_dir`

- **Signature:** `fn sync_parent_dir(&self, path: &str, c: Completion) -> Result<Completion>`
- **Added by:** the orphan-WAL discard prompt (not yet written;
  tracked in
  `issues/issue-01a0e610-b729-7cc3-97e6-e8b99cb808f0-turso-discard-orphan-wal.md`).
- **Why:** under `OrphanWalPolicy::Discard`, a newly created db file
  and its page 1 must be durable before the first WAL frame is
  written. Otherwise a power loss can leave committed WAL frames beside
  a db that looks empty, and `Discard` would delete them. `File::sync`
  covers the file's contents. This covers the file's directory entry.
- **Behaviour by impl:**
  - unix, io_uring, generic-on-unix and `SparseLinuxIo`: open the
    parent directory and fsync it.
  - memory and memory_yield: a no-op returning `Ok`. Nothing survives
    a crash, so there is nothing to make durable.
  - windows and win_iocp: a no-op returning `Ok`, because NTFS
    journals metadata. This still needs confirming by the implementer.
  - `VfsMod`, whose C-ABI extension has no slot for this, and browser
    `Opfs`: `Unsupported`. `Discard` refuses to open on these.
  - Simulator and test IOs: whichever of the above fits.
