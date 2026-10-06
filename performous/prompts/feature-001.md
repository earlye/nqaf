# CI: fork-local macOS DMG workflow with a working dependency cache

## Problem [feature-001]

This repo (`fork.txt`) has no way to build a macOS `.dmg` from a feature
branch. Upstream's `.github/workflows/macports.yml` is a reusable workflow
whose artifact-upload steps are gated on `github.event_name ==
'pull_request'` or `github.ref == 'refs/heads/master'`. Those read the
*caller's* triggering event, so a push-triggered caller runs the whole
1-3h build and uploads nothing; no `workflow_call` input changes that, and
`macports.yml` declares no outputs, so the DMG can't be handed back either.

Upstream's MacPorts dependency cache is also broken, so every macOS build is
a ~70-75 minute cold build (Install Dependencies is ~69 of ~76 minutes).
`actions/cache` runs `tar` as the unprivileged `runner` user for both save
and restore, but every port is installed with `sudo port`, leaving
`/opt/local` full of root-owned files:

- **Save**: bsdtar exits 1 on the first unreadable file (dbus's setuid,
  non-world-readable `dbus-daemon-launch-helper`, pulled in transitively by
  glib2 — it can't be dropped from the port list). The save action
  downgrades this to a warning and reports success, so it goes unnoticed.
  Upstream's existing cleanup only chmods directories under
  `/opt/local/var`, which misses that file.
- **Restore**: even with a saved entry, gtar extracts as `runner`, can't
  `utime` root-owned directories, and can't overwrite the root-owned files
  that `sudo port sync` (in "Amend macports configuration") has already
  repopulated under `/opt/local/var/macports/sources` ("Cannot open: File
  exists"). It exits non-zero and `actions/cache` reports "Cache not found
  for input keys" after downloading the whole ~880MB.
- Upstream uses `Lord-Kamina/always-upload-cache`, whose restore does not
  populate its documented `cache-hit` output, so consumers always see a
  miss; and its `refresh-cache: true` deletes the matched entry before
  re-saving, which from a feature branch would destroy the
  default-branch-scoped entry every branch depends on.

## Fix

Add a new, fork-local workflow `.github/workflows/earlye-mac-dmg.yml`
(name: "Earlye macOS DMG"). It must be a file upstream does not have, so it
survives `git rebase upstream/master` with no conflicts. Do **not** modify
upstream's workflows (`macports.yml`, `build_and_release.yml`, etc.) or any
non-CI file. Start the file with a comment explaining that it is fork-local
and why it is standalone rather than calling `macports.yml`.

Triggers, permissions, concurrency:

- `push` to any branch except `master` (master pushes are upstream syncs),
  plus `workflow_dispatch` with inputs `arch` (choice: `arm64` default,
  `intel`, `both`) and `deployment_target` (optional string override; blank
  means 15.0 for arm64, 12.0 for intel).
- `permissions: contents: read, actions: write`.
- Concurrency group per ref; cancel in progress except on `master` (master
  runs seed the cache and must not be killed).

Jobs:

1. A small `choose` job on `ubuntu-latest` that turns the inputs into a
   matrix `include` JSON: arm64 = `macos-26` / target `15.0`, intel =
   `macos-15-intel` / target `12.0`, with the target override applied to
   both when given.
2. A `dmg` job over that matrix (`fail-fast: false`, `timeout-minutes: 350`
   so it fails visibly rather than hitting the 360 ceiling), with the same
   `BOOST_VERSION` and `MACOS_DEPS` port list as upstream's `macports.yml`.

The `dmg` job's steps, in order:

- Checkout into `performous/` with `fetch-depth: 0` (for `git describe`).
- Compute a version: take `git describe --tags --abbrev=0`, keep the leading
  numeric `X[.Y[.Z]]`, pad to exactly three components (default `1.0.0`),
  and emit `package_version=<X.Y.Z>+git-<short sha>`. `macos-bundler.py`
  does an anchored `re.match` for three components and dereferences the
  result unconditionally, so anything else crashes it. Also emit the short
  SHA and a filesystem-safe copy of the ref name.
- Install MacPorts via `Lord-Kamina/setup-macports` **pinned to a commit
  SHA**, with `enable-cache: 'false'`.
- "Amend macports configuration", "Generate versions file for cache-key"
  and the cache-key computation (`macports-<os>-<hashFiles('cache-key.txt')>`)
  copied **byte-identical** from upstream's `macports.yml`, so the cache key
  matches upstream's. Note in a comment that these must be re-synced when
  upstream changes them.
- Before restoring: `sudo chown -R` `/opt/local` to the runner user, and
  `/Applications/MacPorts` only if that directory exists.
- Restore with stock `actions/cache/restore@v4` (paths `/opt/local/` and
  `/Applications/MacPorts/`), not the always-upload-cache fork. Explain why
  in a comment.
- Unlink Homebrew and Install Dependencies as upstream does, branching on the
  stock action's `cache-hit` output.
- Tar up the MacPorts logs/build dirs (`if: !cancelled()`).
- "Prepare /opt/local for caching": upstream's `find ... -perm 700 -exec
  chmod 755`, then `sudo chown -R` to the runner user and `sudo chmod -R
  a+rX` on `/opt/local`, and the same on `/Applications/MacPorts` **only if
  it exists** (it isn't on every runner image, and an unguarded chmod/chown
  exits 1 and fails the job), then `sudo xattr -c -rsv /opt/local`.
- Save with stock `actions/cache/save@v4`, only when
  `github.ref == 'refs/heads/master'` **and** the restore missed. Only the
  default-branch scope is readable by every branch; feature-branch saves
  burn ~880MB of the 10GB quota each and can evict master's entry. Never use
  `refresh-cache`.
- Build with `osx-utils/macos-bundler.py --flat-output --verify-bundle`,
  passing the computed `--package-version`, `--target`, and
  `--enable-webserver=on --enable-midi=on --enable-webcam=on
  --build-tests=on --prefer-macports`.
- Run unit tests (`build/testing/performous_test --gtest_filter=UnitTest*`
  and `make test` in `build/`).
- Upload the DMG with `actions/upload-artifact`, named
  `Performous-<safe ref>-<short sha>-<arch>-macos<target>`,
  `if-no-files-found: error`, 14-day retention.
- A job summary (`if: always()` once the artifact name is set) listing
  branch, commit, runner/target, artifact name, cache hit/MISS, and the
  `xattr -dr com.apple.quarantine` command needed for the unsigned app.
- Upload the MacPorts logs artifact.
- Last step, with the same master-and-miss gate as the save: verify the cache
  entry exists by querying
  `GET /repos/<repo>/actions/caches?key=<key>` with `curl` and parsing with
  single-line `python3 -c` (not `gh` — "Unlink Homebrew" removes it from
  PATH). Fail with an `::error::` if `total_count` is 0. It runs after the
  DMG upload so a cache regression fails the run without costing the
  artifact.

Pin third-party (non-`actions/*`) actions to commit SHAs rather than moving
refs. Do not make any other changes.
