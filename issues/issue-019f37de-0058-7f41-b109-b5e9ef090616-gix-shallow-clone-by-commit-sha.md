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

## Decided direction: NQAF gix

Rather than a one-off, unmaintained fork, manage this via
[nqaf](https://github.com/earlye/nqaf) — mirror `GitoxideLabs/gitoxide`
into an `earlye-forks/gitoxide`-style fork, patch in object-id/SHA support
for `with_ref_name()` / the fetch-negotiation path (using
`allowReachableSHA1InWant` where the server supports it), and record that
patch as an `nqaf` prompt so it can be auto-re-applied (merge-first,
agent-replay-on-conflict) whenever upstream gitoxide moves — including if
upstream eventually lands its own fix (PRs #2310/#2315 referenced in the
discussion), at which point the patch should become a no-op merge rather
than needing to be dropped by hand.

## Next steps

- Set up the `nqaf` fork-dir (`upstream.txt` → `GitoxideLabs/gitoxide`,
  `fork.txt` → the `earlye-forks` fork) and an initial prompt describing
  the object-id-in-refspec extension.
- Confirm the target API shape: extending `with_ref_name()` itself vs. a
  new `with_object_id()`-style entry point on `PrepareFetch`.
- Revisit whether this is worth the effort at all — only matters if full-clone
  cost on large customer repos turns out to be a real problem in practice.
