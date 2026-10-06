# Bootstrap: mark this repo as a fork tracked via NQAF

## Problem [feature-000]

This repo (`fork.txt`) is a straight mirror of `upstream.txt`
(`performous/performous`) with no indication in the repo itself that it
carries locally-applied changes, or where to find them.

## Fix

Add a short `# About This Fork` section near the top of `README.md`: after
the intro block (the description, the website/wiki/Discord links and the
compiling-instructions line), and before the `# Pre-compiled builds`
section. Use the same heading level as the README's other sections. State:

- This repository is a fork of the upstream project (link to
  `https://github.com/performous/performous`).
- It carries a small set of fork-local changes applied on top of upstream
  (such as a CI workflow that builds macOS DMGs from feature branches),
  tracked as prompts rather than as a diverging code history.
- Anyone re-mirroring this fork from a newer upstream release should look at
  the prompts that produced the current changes (do not hardcode a path to
  the `nqaf` repo here — just say "see the fork's NQAF prompt history").

Do not modify the `# Pre-compiled builds` links, which point at upstream's
releases and nightly builds, or any project/packaging metadata
(`CMakeLists.txt` `project()`/`CPACK_*` settings, `osx-utils/`, `win32/`,
`AppImageBuilder.yml`, etc.). This fork is not published under a new name,
so there is no discoverability problem to solve by rewriting that
metadata — doing so would be speculative scope creep.

Do not make any other changes.
