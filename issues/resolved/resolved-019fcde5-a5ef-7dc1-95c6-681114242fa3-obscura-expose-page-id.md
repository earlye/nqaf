<!--
Hand-off note (not part of the nqaf prompt itself): this file was written
inside another repo's issues/ directory because the writing agent was
sandboxed to that worktree and could not write directly into
earlye/nqaf.git. Everything below the divider is meant to become
`obscura/prompts/feature-NNN.md` in earlye/nqaf.git (fork.txt ->
https://github.com/earlye-forks/obscura, upstream.txt ->
https://github.com/h4ckf0r0day/obscura), following that repo's existing
prompt format (see obscura/prompts/feature-000.md .. feature-009.md for
the convention this mirrors). The next unused number as of this writing
looked like feature-010, but confirm against nqaf's current
obscura/prompts/ contents before assigning it, since more may have been
added since.
-->

# Fix: expose `obscura-browser::Page::id` through the public `obscura` facade

## Problem [feature-NNN]

`obscura-browser::Page` already carries a stable identifier for a page/tab:

```rust
pub struct Page {
    pub id: String,
    pub frame_id: String,
    ...
}
```

(`crates/obscura-browser/src/page.rs:164-206`). The constructor comment notes
this is the Chromium-convention target id: "the main frame's frameId == the
targetId" — i.e. this is CDP's real, stable page/tab identity, not something
invented for internal bookkeeping.

The public embedding facade (`crates/obscura/src/page.rs`), which wraps
`InnerPage` as `pub struct Page { pub(crate) inner: Rc<RefCell<InnerPage>> }`,
never re-exposes it. Its full public surface is `url()`, `content()`,
`evaluate()`, `query_selector()`, `wait_for_selector()`, `settle()`,
`add_preload_script()`, `enable_interception()`, `on_request()`/`on_response()`,
`off_request()`/`off_response()` — no `id()` accessor anywhere.

Net effect: an embedding consumer (i.e. anything depending on the plain
`obscura` crate, not `obscura-cdp`) that holds a live `Page` has no way to
read a stable, browser-assigned identifier for it. Any consumer that needs
to name "this specific open page/tab" from outside the in-process handle —
e.g. to correlate a later, separately-issued action back to the exact page
that produced some earlier result — has to either keep the `Page` value
itself alive and threaded through by hand, or mint its own synthetic id that
isn't actually backed by the browser's own notion of page identity.

## Fix

Add a public accessor to the facade `Page` in `crates/obscura/src/page.rs`
that reads the already-existing `id` field through the existing
borrow-and-read pattern the other accessors already use (cf. `url()`):

```rust
/// Stable identifier for this page/tab (Chromium's CDP `targetId`; the main
/// frame's `frameId` equals it — see `obscura-browser`'s `Page::new`).
pub fn id(&self) -> String {
    self.inner.borrow().id.clone()
}
```

No change needed in `obscura-browser` itself — `id` is already `pub` there;
this only threads an existing value through the facade that currently drops
it.

Add a regression test in `crates/obscura`'s test suite asserting:
- `Page::id()` returns a non-empty string immediately after
  `Browser::new_page()`.
- Two distinct pages from two separate `new_page()` calls return distinct
  ids.

## Why this matters

Without a stable id, an embedding consumer holding a live `Page` has no
browser-native way to reference "this exact page" once execution crosses an
async boundary (a follow-on command arriving later, a separate request that
needs to target the same already-open tab, etc.) — it either has to keep
passing the `Page` object itself around directly, or invent an ad hoc
synthetic identifier disconnected from the browser's own page/tab identity.
Exposing the id costs nothing (the value is already computed and stored on
`InnerPage`) and removes the need for that workaround.
