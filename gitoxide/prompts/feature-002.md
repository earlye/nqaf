## Fix `gix-protocol`'s top-level fetch error so it surfaces the real server-provided reason instead of a fixed generic message

### Problem [feature-002]

`gix-protocol/src/fetch/error.rs` defines:

```rust
#[error("Could not decode server reply")]
FetchResponse(#[from] crate::fetch::response::Error),
```

This is a *fixed* `Display` string on a variant that wraps `crate::fetch::response::Error` via `#[from]`. The wrapped type already carries specific, useful detail in several of its variants — most importantly, when the remote sends an `ERR <message>` packet line (e.g. GitHub's `git-upload-pack` rejecting a `want <sha>` for a commit it doesn't advertise, which plain `git` surfaces as `fatal: remote error: upload-pack: not our ref <sha>`), `gix-packetline`'s `fail_on_err_lines` mechanism catches it and it becomes `response::Error::UploadPack(#[from] gix_transport::packetline::read::Error)`, an `#[error(transparent)]` variant whose `Display` is exactly the server's message text (see `gix-packetline/src/read.rs`, `impl Display for Error`, which just does `Display::fmt(&self.message, f)`). This already works correctly and is covered by an existing test: `gix-protocol/tests/protocol/fetch/response.rs`, `fetch_with_err_response()`, asserts that parsing `v2/fetch-err-line.response` produces `response::Error::UploadPack` whose `.message` is the exact server text (`"segmentation fault\n"` in that fixture).

The bug is one level up: `fetch()` (`gix-protocol/src/fetch/function.rs`, the `crate::fetch::Response::from_line_reader(...).await?` call) uses `?` to convert any `response::Error` into `fetch::Error::FetchResponse` via that `#[from]`. Because the `FetchResponse` variant's `#[error(...)]` attribute is the fixed string `"Could not decode server reply"` rather than something that includes or delegates to `{0}`, this conversion **discards** whatever specific message the wrapped `response::Error` had — including the real server-provided `ERR` text. Any caller that does the natural thing (prints `err.to_string()`, or `{}`-formats the top-level `fetch::Error`) sees only the generic string and has no way to tell "the remote explicitly rejected this ref" apart from "something is broken in the transport." Recovering the real reason requires manually walking `.source()`, which isn't documented or obvious from the type.

This is exactly what makes a shallow fetch by an unadvertised commit SHA (e.g. via `PrepareFetch::with_revision()` + `with_shallow()`) fail with an opaque `"Could not decode server reply"` instead of something recognizably about the unknown revision, even though the real reason is present in the error chain the whole time.

### Fix

In `gix-protocol/src/fetch/error.rs`, change the `FetchResponse` variant so its `Display` includes the wrapped error instead of replacing it:

```rust
#[error("Could not decode server reply: {0}")]
FetchResponse(#[from] crate::fetch::response::Error),
```

`#[error(transparent)]` is also acceptable and arguably preferable (it fully delegates both `Display` and `source()` to the inner `response::Error`, so nothing is duplicated) — but before choosing between the two, grep this fork and any call sites you can see (in `gix`, `gitoxide-core`) for literal matches on `"Could not decode server reply"` to make sure nothing depends on that exact fixed string; if something does, prefer the `{0}`-suffixed form so the prefix stays stable.

Do not add a new public error variant (e.g. a `ServerRejected` variant) for this. The existing `response::Error` variants — especially the transparent `UploadPack` one — already carry the specific reason; the bug was purely that the outer wrapper discarded it when converting. Adding new API surface would be unnecessary scope beyond what's needed to fix the actual problem.

If, while making this specific change, you notice another `fetch`-related error variant in this same file that wraps a `#[from]` source behind an equally-fixed, detail-discarding string, apply the same fix to it too — but don't go looking for unrelated error-message quality issues elsewhere in the crate; keep this to the fetch error path in `gix-protocol/src/fetch/error.rs`.

### Test

Add a test near `fetch_with_err_response()` in `gix-protocol/tests/protocol/fetch/response.rs` (or wherever `fetch::Error` values get constructed in that test module) that specifically exercises the *outer* `fetch::Error::FetchResponse` variant — not just the inner `response::Error::UploadPack` that the existing test already covers — and asserts that `.to_string()` on the outer error contains the server's message text (e.g. the `"segmentation fault\n"` from the existing `v2/fetch-err-line.response` fixture, or a new fixture modeling a `not our ref <sha>`-style message if that's easier to construct against the outer type). The existing test proves the inner detail already survives to `response::Error`; the new test should prove it now also survives the `From`-conversion into `fetch::Error`.

### Update README

Add a bullet to the "Fork Features" section of `README.md` (added by feature-000), e.g.:

* **Fetch errors carry the real server-provided reason**: `gix_protocol::fetch::Error::FetchResponse` used to replace the wrapped error's message with a fixed `"Could not decode server reply"` string, discarding detail like the exact `ERR` text a remote sent (e.g. `upload-pack: not our ref <sha>` when shallow-fetching a commit SHA the remote doesn't advertise). Its `Display` now includes that detail instead of hiding it.
