# gix: shallow fetch by an unadvertised commit SHA fails with generic "Could not decode server reply" instead of a clear "unknown revision" error

## Context

`gix` 0.86.0, via fork `https://github.com/earlye-forks/gitoxide` rev
`ec90039ed1811d9553215b7209f73705ea628cfa` (a thin fork of upstream
gitoxide with no changes to fetch/pack-negotiation code, so this should
reproduce against unmodified upstream gitoxide too).

Transport is SSH (`git@github.com:...`) — gix's SSH transport shells out
to the system `ssh`/`git-upload-pack` — even though the crate is built
with the `blocking-http-transport-reqwest-rust-tls` feature.

API used:

```rust
let (repo, _outcome) = gix::prepare_clone(url, dest)?
    .with_shallow(gix::remote::fetch::Shallow::DepthAtRemote(1.try_into().unwrap()))
    .with_revision(Some(commit_sha))?
    .fetch_only(gix::progress::Discard, &interrupt_flag)?;
```

When the requested `commit_sha` is syntactically valid (40 hex chars) but
doesn't exist on the remote (e.g. a real local commit never pushed), the
fetch fails with a bare `Could not decode server reply` — no indication
that the actual problem is an unknown/unadvertised revision. This is
indistinguishable from a genuine transport corruption, malformed pack, or
protocol version mismatch, which matters for building sensible error
messages/retry logic on top of gix — current calling code just surfaces
this string verbatim to the end user, who has no way to know their commit
simply wasn't pushed yet.

Plain `git` in the same scenario gives a clearly-labeled protocol-level
rejection instead:

```
fatal: remote error: upload-pack: not our ref <sha>
```

## Reproduction steps

1. Pick a real, existing GitHub SSH remote with read access (e.g. a
   private repo).
2. Compute a commit SHA that is syntactically valid (40 hex chars) but
   does not exist on that remote — e.g. a real local commit that was
   never pushed.
3. Call `prepare_clone(url, dest).with_shallow(DepthAtRemote(1)).with_revision(Some(that_sha))?.fetch_only(...)`.

## Root cause hypothesis (unconfirmed)

GitHub's `git-upload-pack` over SSH likely responds to a `want
<unadvertised-sha>` request with something other than the pack-protocol
ACK/NAK negotiation reply gix's client expects next — possibly a plain
error line/packet that gix's negotiation-reply decoder doesn't
special-case, falling through to a generic "couldn't decode this as the
expected reply shape" error instead of checking for an error packet
first.

## Ask

Could the fetch-negotiation reply parser check for (and surface
distinctly) a server-side error/rejection packet before attempting to
decode an ACK/NAK reply, so this class of failure gets a
`FetchError::ServerRejected` (or similar) variant instead of a generic
decode error?

## Related

- `issues/resolved/resolved-019f37de-0058-7f41-b109-b5e9ef090616-gix-shallow-clone-by-commit-sha.md`
  — prior issue about `gix` lacking `with_revision()`/shallow-fetch-by-SHA
  at all. Resolved: upstream shipped `PrepareFetch::with_revision()`
  (gix 0.86.0-era). That issue is about the *happy path* not existing;
  this issue is about the *error path* when the SHA is wrong/unpushed —
  distinct, not a duplicate.
