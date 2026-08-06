# Fix: support shallow clone/fetch of an arbitrary commit SHA via `with_object_id()`

## Problem [feature-001]

The `gix` crate's clone builder, `PrepareFetch` (`gix/src/clone/access.rs`),
only supports checking out a *named* ref:

```rust
pub fn with_ref_name<'a, Name, E>(mut self, name: Option<Name>) -> Result<Self, E>
where
    Name: TryInto<&'a gix_ref::PartialNameRef, Error = E>,
```

Its own doc comment already admits the gap:

> Calling this method with a valid refspec that is not a branch name, like
> an object-id as hex-hash, currently causes subsequent calls to
> [`PrepareFetch::fetch_only`] or [`PrepareFetch::fetch_then_checkout`] to
> panic.

Confirmed by tracing the actual code (against the 0.85.0 release, but the
same shape holds at whatever commit this prompt is applied against — check
first): `with_ref_name()` itself doesn't reject a SHA — a hex string parses
fine as a `gix_ref::PartialNameRef`. The panic happens downstream, in
`find_custom_refname()` (`gix/src/clone/fetch/util.rs`):

```rust
let item = filtered_items[res.mappings[0]
    .item_index
    .expect("we map by name only and have no object-id in refspec")];
```

The fetch path for a named ref (`gix/src/clone/fetch/mod.rs`,
`PrepareFetch::fetch_only`) is: connect → ask the server which refs it
advertises → pattern-match the requested name against *that advertised
list* → use the matched ref's `full_ref_name` to write the tracking ref and
alias `HEAD` to it (`util::update_head`). A commit SHA that isn't pointed
to by any advertised ref has nothing in that list to match, so the
`item_index.expect(...)` above finds no match and panics instead of
returning a proper error.

This is an acknowledged upstream gap (not user error) — see
[GitoxideLabs/gitoxide#2309](https://github.com/GitoxideLabs/gitoxide/discussions/2309)
and the linked draft fixes
[#2310](https://github.com/GitoxideLabs/gitoxide/pull/2310)/[#2315](https://github.com/GitoxideLabs/gitoxide/pull/2315).
Check whether either of those has since merged into the commit this prompt
is being applied against — if so, this prompt is a no-op; verify
`with_object_id()` (or equivalent) already exists and works, and stop.

## Fix

Add a new builder method, kept deliberately separate from `with_ref_name()`
rather than overloading it, because an object-id target needs different
handling at every downstream step (no ref to match by name, no
`full_ref_name` to alias `HEAD` to):

```rust
// gix/src/clone/access.rs
pub fn with_object_id(mut self, id: Option<gix_hash::ObjectId>) -> Self {
    self.object_id = id;
    self
}
```

- Add the `object_id: Option<gix_hash::ObjectId>` field to `PrepareFetch`
  (`gix/src/clone/mod.rs`), defaulting to `None` in the constructor.
- Treat `with_ref_name()` and `with_object_id()` as mutually exclusive —
  return a clear error (or panic with a descriptive message, matching this
  crate's existing convention for programmer-error misuse) if both are set
  when `fetch_only()`/`fetch_then_checkout()` run.
- In `PrepareFetch::fetch_only()` (`gix/src/clone/fetch/mod.rs`), branch
  early on `self.object_id`: if set, skip the named-ref path entirely
  (`find_custom_refname`, the ref-map name-matching, the single-branch
  shallow-refspec construction) and instead:
  - Issue the fetch with an explicit `want <sha>` line for `self.object_id`
    against the remote connection, rather than a name-pattern refspec.
    This requires the server to advertise
    `allowReachableSHA1InWant`/`allowTipSHA1InWant`/`allowAnySHA1InWant`
    (GitHub's git servers do, which is what makes this fixable at all —
    see the test below). If the server doesn't advertise any of these,
    fail with a clear, typed error naming the missing capability — do not
    silently fall back to a full clone.
  - Skip `util::update_head()`'s named-ref lookup and instead write `HEAD`
    as **detached**, pointing directly at `self.object_id`, once the fetch
    completes. There is no `full_ref_name` to alias to, so this must not
    attempt to create or update any ref other than `HEAD` itself.
  - Respect `with_shallow()` as it already does for the named-ref path
    (e.g. `Shallow::DepthAtRemote(1)`), so this composes with shallow
    depth exactly like ref-based clones do today.
- Leave every existing `with_ref_name()` code path completely untouched —
  this must be a strictly additive, parallel branch, not a refactor of the
  name-matching logic. Existing tests for named-ref clones must keep
  passing unmodified.

Add a regression test (new test module under `gix/tests/` following this
crate's existing clone-test conventions) that:

- Shallow-fetches commit `c3d319f2b3076a0bb169bcd8a7b6a011f6aba9a5` — this
  *very* upstream repo's actual root commit (2018-06-07, "Initial commit -
  based on standard project template"; 9 small files: `.editorconfig`,
  `.gitignore`, `Cargo.toml`, `Makefile`, `README.md`,
  `etc/developer.Dockerfile`, `src/main.rs`,
  `tests/stateless-journey.sh`, `tests/utilities.sh`) — from the real
  upstream remote (`https://github.com/GitoxideLabs/gitoxide`) via
  `PrepareFetch::with_object_id(...)`.
- Asserts the fetch succeeds, `HEAD` is detached and points at that exact
  SHA, and the working tree contains those 9 files.
- Asserts only that one commit was transferred, not the repo's full
  history (e.g. `git log --oneline` / the equivalent `gix` revwalk from
  `HEAD` returns exactly one commit).
- This SHA is a real, public, permanently-immutable root commit (nothing
  can rewrite it), so the test has no dependency on a synthetic local
  fixture repo and exercises the real `allowReachableSHA1InWant`
  negotiation against GitHub's actual server end-to-end.

## Why this matters

Without this, any caller that only has a resolved commit SHA (not a branch
or tag name) for the ref they want — e.g. a content-addressed clone cache
keyed by commit SHA, which is exactly what motivated this fix — cannot use
`gix`'s shallow-clone convenience API at all. They're forced into a full,
non-shallow clone (fetching the entire history) just to reach one commit,
paying full bandwidth/disk cost on large repos for what should be a cheap,
single-commit fetch.
