# Fix: `SECURITY.md` claims a `cargo-deny`/`deny.toml` gate that doesn't exist

## Problem [feature-007]

`SECURITY.md` describes this project's dependency-vetting posture as including
a `cargo-deny` check (advisory-database scanning for known-vulnerable/yanked
crates, a license allowlist, and/or a banned-crate/banned-source list gate run
in CI). No `deny.toml` exists anywhere in the repository, and no CI workflow
invokes `cargo deny`. Anyone relying on `SECURITY.md` as an accurate
description of this fork's posture — including consumers who chose this fork
specifically for its stated security practices — is trusting a check that
does not run.

This is not a code vulnerability by itself, but it is a false claim about a
control that a downstream consumer might reasonably factor into their own risk
assessment (e.g. deciding they don't need to separately audit dependencies
because "the project already gates on this").

## Fix

Make the claim true rather than walking it back: add an actual `deny.toml` at
the workspace root and wire `cargo deny check` into CI so it runs on every
push/PR, matching what `SECURITY.md` already says the project does.

Concretely:

- Add `deny.toml` covering, at minimum, the pieces `SECURITY.md` describes:
  - `[advisories]`: deny crates with known RUSTSEC security advisories; deny
    yanked crate versions.
  - `[licenses]`: an allowlist of licenses already in use by this workspace's
    actual dependency tree (check `cargo tree`/existing `Cargo.lock` for what's
    really in use before picking the list, so the initial gate doesn't
    immediately fail on the project's own current dependencies).
  - `[bans]`: deny multiple-versions-of-the-same-crate only as a `warn` (not a
    hard failure) unless the project already has a stated zero-duplicate
    policy — a hard `deny` here is easy to make in a way that breaks on the
    next routine dependency bump for reasons unrelated to security.
  - `[sources]`: restrict to crates.io as the allowed registry/source (this
    project's dependencies are already git-free per the existing review — keep
    it that way by gating on it).
- Add a CI job (or a step in the existing CI workflow) that installs
  `cargo-deny` and runs `cargo deny check` against this config, failing the
  build on violations.
- Run it once locally against the current workspace before wiring it into CI,
  and resolve (or explicitly, narrowly exempt with a comment explaining why)
  any violation it finds on day one — the gate should start green, not start
  broken.
- Do not change the wording of `SECURITY.md`'s existing claim; once the gate
  exists, the claim is accurate as written.

## Why this matters

`SECURITY.md` is the document this fork's consumers are told to trust as an
accurate description of its security posture (the review this prompt comes
from cross-checks findings against exactly that document). A stated control
that doesn't exist is worse than no stated control at all, because it creates
false confidence. Implementing the gate — rather than just softening the
document's wording — also has real, ongoing value: it catches known-vulnerable
or yanked dependencies automatically on every future change, not just at
review time.
