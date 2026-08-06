# Fork gix to support shallow clone/fetch of an arbitrary commit SHA

## Resolution: no fork needed — upstream already shipped this

**Status: resolved without a fork.** During implementation (self-review of
the drafted `nqaf` prompt), found that `GitoxideLabs/gitoxide` merged
[`PrepareFetch::with_revision()`](https://github.com/GitoxideLabs/gitoxide/commit/b1174b69b60b478be24f0b81787e95ac08564e7e)
via PR [#2824](https://github.com/GitoxideLabs/gitoxide/pull/2824) on
2026-08-05 — the exact capability this issue asked for. (The commit's own
message cites `#1930`, but that's the *issue* it closes, not the PR; the
commit's author-date, 2026-07-24, is also earlier than its actual merge —
confirm both via `gh api` before citing either elsewhere.) It wasn't
visible in the earlier research because `gix` 0.86.0 was published to
crates.io on 2026-07-23, **13 days before** the fix merged; as of
2026-08-06 it exists on upstream `main` only, not in any released crate.
Verified directly against gitoxide's own test suite
(`gix/tests/gix/clone.rs`, `fetch_specific_revision_bare_and_shallow` and
`fetch_and_checkout_specific_revision`) that `with_revision()` accepts a
full object-id (not just `HEAD`/a full ref name), and separately that
`with_shallow(Shallow::DepthAtRemote(1))` composes with it to actually
produce a shallow clone (`repo.is_shallow() == true`, detached `HEAD`, no
ordinary refs or persisted fetch refspec) — but see the caveat below,
these two are not exercised *together* in any upstream test.

**Two caveats, unverified upstream — confirm before relying on this in
automaton:**

- **No upstream test covers object-id + shallow together.**
  `fetch_specific_revision_bare_and_shallow` (the only test using
  `with_shallow`) passes a ref name (`"refs/heads/a"`), not a SHA.
  `fetch_and_checkout_specific_revision` has the object-id case but never
  combines it with `with_shallow`. The code path is the same regardless of
  how `revision` was sourced, so this should work, but it's inferred, not
  directly tested upstream — worth a quick smoke test before depending on
  it.
- The object-id test case there also uses a branch tip's SHA over a local
  test-fixture transport, not an arbitrary non-tip commit over a real
  network remote. This should still work against GitHub (which advertises
  `allowReachableSHA1InWant`, i.e. permits `want` for any object reachable
  from an advertised ref, not just tips) — but it hasn't been exercised
  end-to-end against a real remote for a non-tip commit either.

**What this means for the parent issue** (`script_ref`-driven
content-addressed clone cache in automaton — tracked as
`issue-019f2414-5b0d-74d0-9156-66dabfca369a-use-git-ref-from-task-created.md`
in the *automaton* repo's own `issues/`, not in this `nqaf` repo): point
automaton's `Cargo.toml` at a git dependency on `GitoxideLabs/gitoxide`
pinned to commit `b1174b69b60b478be24f0b81787e95ac08564e7e` (or later, or
the next crates.io release once one ships that includes it — check
`with_revision` exists on `PrepareFetch` before bumping), and use:

```rust
let (repo, _outcome) = gix::clone::PrepareFetch::new(url, path, gix::create::Kind::Bare, Default::default(), open_opts)?
    .with_revision(Some(sha.to_string()))?
    .with_shallow(gix::remote::fetch::Shallow::DepthAtRemote(1.try_into()?))
    .fetch_only(gix::progress::Discard, &should_interrupt)?;
```

(`fetch_only` returns `(Repository, fetch::Outcome)`, matching upstream's
own tests — don't bind the tuple directly to a single `repo` variable.)

This shallow-fetches exactly `sha`, detaches `HEAD` at it, and persists no
tracking ref or fetch refspec — no fork, no patch, no `nqaf` prompt
required, **once the two caveats above are confirmed**. The `gitoxide/`
fork-dir drafted while investigating this has been removed from this repo
(`git rm -r gitoxide/`). The `earlye-forks/gitoxide` GitHub repo created to
hold it still exists as of this writing and needs manual deletion — see
Next steps below.

The rest of this file below is kept as the historical record of the
investigation that led here (initial report, root-cause dig against the
stale 0.85.0 source, and the grill that refined the now-superseded fork
plan before this was found) — **it is superseded by the Resolution above
and no longer reflects current fact** (in particular, "no merged fix as of
that discussion" in Context, below, is no longer true; it was true only as
of the 0.85.0-era research, before PR #2824 merged).

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

## Decided direction: NQAF gix (superseded — see Resolution above)

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

## Live next steps

- [ ] **Delete the `earlye-forks/gitoxide` GitHub repo** — created during
  this investigation, then found unnecessary. Still exists as of this
  writing; the `gh` token used in this session lacked `delete_repo` scope,
  so this needs a human (or a re-authed token) to run
  `gh repo delete earlye-forks/gitoxide --yes`.
- [ ] Confirm the two caveats in the Resolution section above (object-id +
  shallow together; non-tip SHA over a real remote) before automaton
  depends on this.
- [ ] Bump automaton's `gix` dependency per the Resolution section above,
  once `script_ref` wiring is ready for it.

### Superseded next steps (historical — the fork was abandoned)

- ~~Create the `earlye-forks/gitoxide` repo on GitHub~~ — see live next
  steps above; done, then found unnecessary.
- ~~Set up the `nqaf` fork-dir at `gitoxide/`~~ — done, then reverted
  (`git rm -r gitoxide/`) once `with_revision()` was found upstream.

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

### 2026-08-06 (implementation self-review — plan superseded)

Self-review of the drafted `gitoxide/prompts/feature-001.md` (via
`pr-review-toolkit:code-reviewer`) found that upstream gitoxide had already
merged `PrepareFetch::with_revision()` — the exact fix this prompt asked a
future agent to build. Independently verified against gitoxide's own test
suite that `with_revision()` + `with_shallow()` produces a real shallow
clone of an arbitrary commit SHA with a detached HEAD. Reverted course:
deleted the `gitoxide/` fork-dir, asked the user to confirm before treating
this as settled, then — per direction — dropped the fork entirely,
attempted (partially blocked on `gh` token scope) to delete the
`earlye-forks/gitoxide` repo, and wrote the Resolution section above for
whoever wires up `script_ref` in automaton.

A second review pass (same agent, against the final diff) caught two more
issues in that Resolution section, now fixed: it cited the wrong PR number
and merge date for the upstream fix (the commit message references issue
`#1930`, not the actual merging PR `#2824`; the commit's *author* date,
2026-07-24, isn't its merge date, 2026-08-05 — so gix 0.86.0 predates the
fix by 13 days, not 1), the code sample didn't compile (`fetch_only`
returns a `(Repository, Outcome)` tuple, not a bare `Repository`), and it
missed that no upstream test actually combines the object-id and shallow
paths together (only each individually) — now called out as a caveat to
confirm before automaton depends on it.
