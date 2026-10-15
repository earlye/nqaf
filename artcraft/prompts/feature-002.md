# CI: fork-local workflow that builds the desktop app on every push

## Problem [feature-002]

This repo (`fork.txt`) has no way to get a runnable build of a feature
branch. Upstream's two workflows, `.github/workflows/artcraft-macos-publish.yml`
and `artcraft-windows-publish.yml`, only run on pushes to `release`,
`artcraft-release`, `artcraft-macos` and `artcraft-windows`. They publish
draft GitHub releases through `tauri-apps/tauri-action` with a `tagName`.
The macOS one also needs upstream's Apple signing and notarization secrets
(`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`,
`APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`), and it
runs on the paid `macos-latest-xlarge` runner. This fork has neither, so
those workflows can't produce a build here.

## Fix

Add a new, fork-local workflow `.github/workflows/earlye-build.yml`
(name: "Earlye build"). It must be a file upstream does not have, so it
survives rebases onto upstream with no conflicts. Do **not** modify
upstream's workflows, `tauri.conf.json`, `tauri-mac.conf.json`, or any
non-CI file. Start the file with a comment saying it is fork-local, that it
builds **unsigned** artifacts for testing, and why it is standalone rather
than reusing the publish workflows (they need secrets and create releases).

Triggers, permissions, concurrency:

- `push` to every branch except `main` (the fork's default branch, used
  for upstream syncs) and upstream's release branches (`release`,
  `artcraft-release`, `artcraft-macos`, `artcraft-windows`), so it doesn't
  duplicate the publish workflows.
- `workflow_dispatch` with a `platform` choice input: `macos+windows`
  (default), `macos`, `windows`, `linux`, `all`. Pushes build
  `macos+windows`. Linux has never been built in upstream CI, so it is
  opt-in only.
- `permissions: contents: read`. The workflow must never create releases
  or tags.
- Concurrency group per ref, `cancel-in-progress: true`.

Jobs:

1. A small `choose` job on `ubuntu-latest` that turns the trigger or input
   into a matrix `include` JSON:
   - macOS: `macos-latest` (arm64), target `aarch64-apple-darwin`, bundles
     `app,dmg`.
   - Windows: `windows-latest`, bundles `nsis`.
   - Linux: `ubuntu-22.04`, bundles `deb,appimage`.
2. A `build` job over that matrix (`fail-fast: false`, with a generous
   `timeout-minutes`, e.g. 180).

The `build` job's steps, in order:

- Checkout.
- Node `lts/*` via `actions/setup-node`, with npm caching on
  `frontend/package-lock.json`.
- Rust stable via `dtolnay/rust-toolchain`, with the matrix target. Then
  `Swatinem/rust-cache`, keyed per OS/target, with the workspace-root
  `target/` as the target dir.
- Platform prerequisites, mirroring upstream:
  - Windows: `choco install cmake strawberryperl pkgconfiglite llvm nasm -y`
    (needed by `wreq`).
  - Linux: `libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev
    patchelf`, plus `cmake clang perl pkg-config` for `wreq`.
  - macOS: rely on the runner image, as upstream does.
- Compute a short SHA and a filesystem-safe copy of the ref name.
- `cd frontend && npm ci`, then build the frontend with
  `NODE_OPTIONS=--max-old-space-size=8192` and `npx nx run artcraft:build`.
  Set `VITE_ENVIRONMENT_TYPE=production`, as
  `script/artcraft/unix_build.sh` and `windows_build.ps1` do.
- Install `tauri-cli` (pin the major/minor upstream documents in
  `_docs/dev_setup.md`, using a cached binary install such as
  `taiki-e/install-action` or `cargo install --locked`).
- From `crates/desktop/artcraft`, run `cargo tauri build --target <target>`
  (omit `--target` on Windows/Linux if that matches upstream's output paths)
  with `--bundles <matrix bundles>` and
  `--config '{"build":{"beforeBuildCommand":""}}'`. The frontend is already
  built, and passing `--config` avoids mutating the tracked config file as
  upstream does. Env: `SQLX_OFFLINE: true`, and on Windows
  `RUSTFLAGS: "-C target-feature=+crt-static"` (needed by `wreq`). Do not
  set any `APPLE_*` signing variables, so tauri skips signing.
- Zip the macOS `.app` with `ditto -c -k --keepParent`, to preserve
  symlinks and permissions.
- Upload with `actions/upload-artifact` the DMG plus the zipped `.app`
  (macOS), the NSIS installer (Windows), or the deb/AppImage (Linux).
  Name it `ArtCraft-<safe ref>-<short sha>-<os>`, with
  `if-no-files-found: error` and 14-day retention. Bundles land under the
  workspace-root `target/` (e.g.
  `target/<target>/release/bundle/dmg/*.dmg`); verify the actual paths
  rather than guessing.
- A job summary (`if: always()`) listing branch, commit, runner, target,
  artifact name and the rust-cache hit status. For macOS, include the
  `xattr -dr com.apple.quarantine /Applications/ArtCraft.app` command
  needed to open the unsigned app. For Windows, note that SmartScreen will
  warn about the unsigned installer.

Pin third-party (non-`actions/*`) actions to commit SHAs rather than
moving refs. Validate the workflow YAML (for example with `actionlint` if
available) before finishing.

Add a bullet to the `## Differences from upstream` section of
`earlye-fork.md` (create the file with that section if it doesn't exist):
`feature-002` — adds the fork-local `earlye-build.yml` workflow, which
builds unsigned macOS (arm64) and Windows artifacts on every push to a
non-`main` branch, with Linux available on manual dispatch.

Do not make any other changes.
