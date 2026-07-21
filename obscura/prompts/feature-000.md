# Bootstrap: mark this repo as a fork tracked via NQAF

## Problem [feature-000]

This repo (`fork.txt`) is a straight mirror of `upstream.txt`
(`h4ckf0r0day/obscura`) with no indication in the repo itself that it carries
locally-applied fixes, or where to find them.

## Fix

Add a short section near the top of `README.md`, right after the intro
paragraph and before the feature/comparison table, stating:

- This repository is a fork of the upstream project (link to the URL in
  `upstream.txt`).
- It carries a set of security and correctness fixes applied on top of
  upstream, tracked as prompts rather than as a diverging code history.
- Anyone re-mirroring this fork from a newer upstream release should look at
  the prompts that produced the current fixes (do not hardcode a path to the
  `nqaf` repo here — just say "see the fork's NQAF prompt history").

Do not modify any `Cargo.toml` `repository`/`homepage` metadata fields. This
project is consumed as a git dependency, not published to crates.io under a
new name, so there is no crates.io/docs.rs discoverability problem to solve
by rewriting package metadata — doing so would be speculative scope creep.

Do not make any other changes.
