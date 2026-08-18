## Fix `gix-protocol`'s top-level fetch error so it surfaces the real server-provided reason instead of a fixed generic message

### Problem [feature-002]

`gix-protocol/src/fetch/error.rs` defines:

```rust
#[error("Could not decode server reply")]
FetchResponse(#[from] crate::fetch::response::Error),
```

This is a *fixed* `Display` string on a variant that wraps `crate::fetch::response::Error` via `#[from]`. The wrapped type already carries specific, useful detail in several of its variants. For example, when the remote sends an `ERR <message>` packet line (e.g. GitHub's `git-upload-pack` rejecting a `want <sha>` for a commit it doesn't advertise — plain `git` illustrates this case as `fatal: remote error: upload-pack: not our ref <sha>`, though the exact wording isn't guaranteed), and `gix-packetline`'s `fail_on_err_lines` check is active on the reader at the time, it becomes `response::Error::UploadPack(#[from] gix_transport::packetline::read::Error)`, an `#[error(transparent)]` variant whose `Display` is exactly the server's message text (see `gix-packetline/src/read.rs`, `impl Display for Error`, which just does `Display::fmt(&self.message, f)`). This path is covered by an existing test: `gix-protocol/tests/protocol/fetch/response.rs`, `fetch_with_err_response()`, asserts that parsing `v2/fetch-err-line.response` with `fail_on_err_lines(true)` produces `response::Error::UploadPack` whose `.message` is the exact server text (`"segmentation fault\n"` in that fixture).

`fail_on_err_lines` defaults to `false` and is only turned on by `Handshake::from_lines_with_version_detection` (`gix-transport/src/client/capabilities.rs`) during the initial handshake, on the specific `StreamingPeekableIter` reader instance it's called on. Whether it's still `true` by the time the fetch-negotiation response is read later depends on the transport:
- Stateful, single-reader transports (the `ssh`/`git://`/local-process transports in `gix-transport/src/client/git/blocking_io.rs`) reuse the same `line_provider` for the whole connection and never call `.replace()` on it between requests, so the flag set at handshake time stays `true` — the `UploadPack` path above applies.
- The HTTP transport calls `line_provider.replace(body)` per request (`gix-transport/src/client/blocking_io/http/mod.rs`), and `replace()` unconditionally resets `fail_on_err_lines` back to `false` (`gix-packetline/src/read.rs`) — so over HTTP, the same `ERR ...` line instead falls through as an unrecognized data line, most likely surfacing as `response::Error::UnknownSectionHeader` or `UnknownLineType` (`gix-protocol/src/fetch/response/io.rs`, `response/mod.rs`) rather than `UploadPack`.

Either way, `response::Error`'s `Display` for the variant that actually gets produced still contains the real text the server sent (verbatim for `UploadPack`; embedded in the line for `UnknownSectionHeader`/`UnknownLineType`). The bug this prompt fixes is one level up and applies regardless of which `response::Error` variant occurs: `fetch()` (`gix-protocol/src/fetch/function.rs`, the `crate::fetch::Response::from_line_reader(...).await?` call) uses `?` to convert any `response::Error` into `fetch::Error::FetchResponse` via that `#[from]`. Because the `FetchResponse` variant's `#[error(...)]` attribute is the fixed string `"Could not decode server reply"` rather than something that includes `{0}`, this conversion **discards** whatever specific message the wrapped `response::Error` had. Any caller that does the natural thing (prints `err.to_string()`, or `{}`-formats the top-level `fetch::Error`) sees only the generic string and has no way to tell "the remote explicitly rejected this" apart from "something is broken in the transport." Recovering the real reason requires manually walking `.source()`, which isn't documented or obvious from the type.

This is exactly what makes a shallow fetch by an unadvertised commit SHA (e.g. via `PrepareFetch::with_revision()` + `with_shallow()`) fail with an opaque `"Could not decode server reply"` instead of something recognizably about the unknown revision, even though the real reason is present in the error chain the whole time. The wrapping chain above `FetchResponse` (e.g. `gix/src/remote/connection/fetch/error.rs`, `gix/src/clone/fetch/mod.rs`) is already `#[error(transparent)]` all the way out to `PrepareFetch` callers, so fixing this one variant is sufficient to reach them — no changes needed in the `gix` crate itself.

### Fix

In `gix-protocol/src/fetch/error.rs`, change the `FetchResponse` variant so its `Display` includes the wrapped error instead of replacing it:

```rust
#[error("Could not decode server reply: {0}")]
FetchResponse(#[from] crate::fetch::response::Error),
```

Use exactly this `{0}`-suffixed form, not `#[error(transparent)]`. Transparent would also work for `Display`, but it additionally changes `source()` to forward *through* this variant rather than stopping at it, which would drop `response::Error` out of the visible error chain for any caller doing `err.source()`-based introspection (e.g. downcasting) — a behavior change beyond what this fix needs. The `{0}` form keeps the existing "Could not decode server reply" prefix stable (in case anything matches on it) while appending the real detail, and leaves everything else — including `IsSpuriousError`'s `Error::FetchResponse(err) => err.is_spurious()` — untouched.

Do not add a new public error variant (e.g. a `ServerRejected` variant) for this. The existing `response::Error` variants already carry the specific reason; the bug was purely that the outer wrapper discarded it when converting. Adding new API surface would be unnecessary scope beyond what's needed to fix the actual problem.

Keep this fix to the `FetchResponse` variant only. Do not touch the other variants in `gix-protocol/src/fetch/error.rs` (`WriteShallowFile`, `ReadShallowFile`, `LockShallowFile`, `ConsumePack`, `ReadRemainingBytes`) even though some of them have a similar fixed-string-over-`#[from]`/`#[source]` shape — that's out of scope for this prompt and would make the applied diff bigger and less predictable across re-applications to newer upstreams than the one thing this issue is actually about.

### Test

Add a test alongside `fetch_with_err_response()` in `gix-protocol/tests/protocol/fetch/response.rs` that exercises the *outer* `fetch::Error::FetchResponse` variant (the existing test only covers the inner `response::Error::UploadPack`, which is not what this fix changes). Concretely: reuse the same `mock_reader("v2/fetch-err-line.response")` fixture and `provider.fail_on_err_lines(true)` setup as `fetch_with_err_response()`, run it through `fetch::Response::from_line_reader(...)` the same way to get a `response::Error`, convert it into `fetch::Error` via `fetch::Error::from(...)` (or however the crate's own code performs that `?`-driven conversion), and assert `err.to_string().contains("segmentation fault")` — use `contains`, not `assert_eq!`, since the fixture's message ends in a trailing newline. Give the new test the same attribute stack as its neighbors in that file (`#[crate::bisync::bisync]`, `#[cfg_attr(feature = "blocking-client", test)]`, `#[cfg_attr(all(feature = "async-client", not(feature = "blocking-client")), async_std::test)]`) — a plain `#[test]` won't compile under the async-only feature combination this crate's test suite also runs.

### Update README

Add a bullet to the "Fork Features" section of `README.md` (added by feature-001; the surrounding "About This Fork" section was added by feature-000), e.g.:

* **Fetch errors carry the real server-provided reason**: `gix_protocol::fetch::Error::FetchResponse` used to replace the wrapped error's message with a fixed `"Could not decode server reply"` string, discarding whatever detail the server actually sent (e.g. the text of an `ERR` line when a remote rejects a `want` for a commit it doesn't advertise). Its `Display` now includes that detail instead of hiding it.
