# Fork gix to support shallow clone/fetch of an arbitrary commit SHA

## Context

Follow-up from `issue-019f2414-5b0d-74d0-9156-66dabfca369a-use-git-ref-from-task-created.md`
(wiring up `script_ref` so automaton actually clones/checks out task repos).

That issue settled on `gix` (pure Rust, no libgit2/OpenSSL C toolchain
dependency) for git operations, and originally wanted a shallow, content-addressed
clone cache keyed by resolved commit SHA. `gix` cannot do this today: its
`PrepareFetch::with_ref_name()` only accepts named refs (branches/tags), not a
commit hash — passing a SHA panics with "we map by name only and have no
object-id in refspec." Confirmed via the gitoxide maintainers in
[GitoxideLabs/gitoxide#2309](https://github.com/GitoxideLabs/gitoxide/discussions/2309):
this is an acknowledged gap, not user error, with no merged fix as of that
discussion.

As a result, the parent issue ships with full (non-shallow) clones instead of
shallow ones. Each `(repo, commit)` pair is still only cloned once thanks to
the content-addressed cache, so this is a one-time cost rather than a
per-timeslice one — but it means large repos pay full-clone bandwidth/disk
cost on first use instead of a cheap shallow fetch.

## Root cause (confirmed against `gix` 0.85.0 source, cached locally under `~/.cargo/registry`)

The panic is not in `with_ref_name()`'s validation — a hex SHA parses fine
as a `gix_ref::PartialNameRef`. It happens downstream, in
`find_custom_refname()` (`clone/fetch/util.rs:294`,
`item_index.expect("we map by name only and have no object-id in refspec")`).

The actual fetch path (`clone/fetch/mod.rs:137-213`) for a named ref is:
connect → ask the server which refs it advertises → pattern-match the
requested name against *that advertised list* → use the matched ref's
`full_ref_name` to write the tracking ref and alias HEAD to it
(`util::update_head`). A commit SHA that isn't pointed to by any advertised
ref has nothing in that list to match, so the code path that assumes a
match always exists blows up.

**Implication:** the fix isn't a signature tweak on `with_ref_name()` — an
object-id target needs a genuinely different code path afterward: a direct
protocol-level `want <sha>` instead of name-matching (gated on the server
advertising `allowReachableSHA1InWant`/`allowAnySHA1InWant`), and a
**detached HEAD written directly at that SHA** instead of aliasing to a
`full_ref_name` (there isn't one to alias to).

## Decided direction: NQAF gix

Rather than a one-off, unmaintained fork, manage this via
[nqaf](https://github.com/earlye/nqaf) — mirror `GitoxideLabs/gitoxide`
into an `earlye-forks/gitoxide`-style fork, add object-id/SHA support via a
new entry point (see API shape below), and record that patch as an `nqaf`
prompt so it can be auto-re-applied (merge-first, agent-replay-on-conflict)
whenever upstream gitoxide moves — including if upstream eventually lands
its own fix (PRs #2310/#2315 referenced in the discussion), at which point
the patch should become a no-op merge rather than needing to be dropped by
hand.

**Worth doing now:** yes — confirmed via grill, not deferred. Proceed with
the fork-dir + prompt.

### API shape: `with_object_id()`, not an overloaded `with_ref_name()`

Add `PrepareFetch::with_object_id(Option<ObjectId>)`, mutually exclusive
with `with_ref_name()`. `fetch_only()` branches early: if an object-id is
set, skip `find_custom_refname`/ref-map name-matching entirely, send a
direct `want <sha>` (erroring clearly if the server doesn't advertise
`allowReachableSHA1InWant`/`allowAnySHA1InWant`), then have `update_head()`
write a detached HEAD directly at that SHA. This leaves the existing
name-based path completely untouched (lowest regression risk) and mirrors
the shape of upstream's own discussed fix (#2310/#2315), so a future
upstream merge should collapse cleanly onto this instead of conflicting
with it.

```rust
let repo = gix::clone::PrepareFetch::new(url, path, kind, opts, open_opts)?
    .with_object_id(Some(sha))?   // NEW — mutually exclusive with with_ref_name()
    .with_shallow(gix::remote::fetch::Shallow::DepthAtRemote(1.try_into()?))
    .fetch_only(progress, &should_interrupt)?;
```

### Test strategy: pin gitoxide's own root commit as the fixture

Regression test shallow-fetches `c3d319f2b3076a0bb169bcd8a7b6a011f6aba9a5`
(gitoxide's actual root commit, confirmed via GitHub API: 2018-06-07,
"Initial commit - based on standard project template", 9 small files —
`README.md`, `Cargo.toml`, a `Makefile`, one `src/main.rs`, no prior
history) from the real upstream `GitoxideLabs/gitoxide` remote. Assert the
fetch succeeds, HEAD ends up detached at that SHA, and only that one commit
(not the full 16000+ commit history) was transferred. Meta but fitting: it
targets the exact codebase under patch, the SHA is permanently immutable
(nothing can rewrite a public root commit), and it exercises the real
`allowReachableSHA1InWant` negotiation against GitHub's actual server
end-to-end rather than a synthetic local repo.

## Next steps

- Create the `earlye-forks/gitoxide` repo on GitHub (empty — confirmed via
  `gh repo view` that it doesn't exist yet). Blocks `scripts/mirror`, which
  needs an existing remote to push `--mirror` into.
- Set up the `nqaf` fork-dir at `gitoxide/` (matches the existing
  obscura/postgresparser convention of naming the dir after the upstream
  repo, not the crate) — `upstream.txt` → `GitoxideLabs/gitoxide`,
  `fork.txt` → `earlye-forks/gitoxide` — and an initial
  `prompts/feature-000.md` implementing `with_object_id()` per the API
  shape and test strategy above.

## Grill Log

### 2026-08-06

- Q: Given the fix is a real feature addition to gix (not a signature
  tweak), and the parent issue already works today via full clones — is
  this still worth doing now? — A: Yes, do it now, patch gix. (Ruled out:
  parking it as a backlog note; bypassing gix's clone layer entirely and
  writing custom fetch logic against gix-protocol/gix-transport directly
  in automaton.)
- Q: What should the new API surface look like on `PrepareFetch` — extend
  `with_ref_name()` or add a new `with_object_id()` entry point? — A: New
  `with_object_id()` method, mutually exclusive with `with_ref_name()`;
  `fetch_only()` branches early to a want-negotiation path that skips
  `find_custom_refname()` and writes a detached HEAD.
- Q: Fork-dir name — `gitoxide/` (matches upstream repo name convention) or
  `gix/` (matches the crate name)? — A: `gitoxide/`, consistent with how
  obscura/postgresparser/md2confluence-mcp are all named after the upstream
  repo.
- Q: Should creating the not-yet-existing `earlye-forks/gitoxide` GitHub
  repo be tracked as an explicit next step? — A: Yes, added as a step
  blocking `scripts/mirror`.
- Q: What should the `with_object_id()` regression test target — a real
  remote or a local bare repo spun up in-process? — A: User proposed
  testing against gitoxide's own history directly. Confirmed via GitHub API
  that its root commit is `c3d319f2b3076a0bb169bcd8a7b6a011f6aba9a5` (tiny,
  immutable) — pinned that exact SHA as the fixture.
