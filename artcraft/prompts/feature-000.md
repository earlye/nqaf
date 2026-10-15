# Bootstrap: mark this repo as a fork tracked via NQAF

## Problem [feature-000]

This repo (`fork.txt`) is a straight mirror of `upstream.txt`
(`storytold/artcraft`) with no indication in the repo itself that it
carries locally-applied changes, or where to find them.

## Fix

Add a short fork notice near the top of `README.md`: after the centered
intro block (the title, tagline, demo video, social badges, and the
"Download ArtCraft · GitHub releases · Build from source" links row), and
before the next section. Match the README's existing style. State:

- This repository is a fork of the upstream project (link to
  `https://github.com/storytold/artcraft`).
- It carries a small set of fork-local changes applied on top of upstream,
  tracked as prompts rather than as a diverging code history.
- For how this fork differs from upstream, see
  [`earlye-fork.md`](./earlye-fork.md).

Create `earlye-fork.md` at the repo root containing:

- A one-paragraph explanation that this is a fork of
  `https://github.com/storytold/artcraft`, maintained by re-applying a set
  of change prompts on top of upstream (do not hardcode a path to the
  `nqaf` repo — just say "see the fork's NQAF prompt history").
- A `## Differences from upstream` section with one bullet per fork-local
  change. Add only this change's bullet: `feature-000` — adds this file and
  the fork notice in `README.md`. Later prompts add their own bullets.

Do not change the existing README links (download, releases, Discord,
etc.), which point at upstream, or any app/packaging metadata
(`tauri.conf.json` identifiers, `Cargo.toml`/`package.json` names,
repository/homepage fields, updater endpoints). This fork is not published
under a new name, so rewriting that metadata would be speculative scope
creep.

Do not make any other changes.
