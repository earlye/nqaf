# firkin v1 design (seed for firkin-media/firkin)

## Context

> firkin is an app that knows all media, selectively syncs it to/from
> your machine, and provides an integration mechanism for other apps.

**Origin.** The starting request was for Performous (a karaoke/rhythm
game) to search online song servers and download songs from them. The
original inspiration was rhythmverse.co
(https://rhythmverse.co/songfiles/game). Existing sources were rejected
as the core:

- USDB (usdb.animux.de) serves only UltraStar `.txt` charts, behind a
  login, with no API. Media comes from YouTube links, fetched with
  yt-dlp (as USDB Syncer does, GPL-3.0).
- Upstream Performous has open issues for torrent distribution
  (performous#4) and YouTube download (performous#551). Maintainers
  pushed back on the legality of the latter.

What came out of that is a neutral protocol and tool. Whether a
catalog's content is legal is the responsibility of whoever publishes
the catalog, not of firkin or the apps that use it.

**Vision.** Rhythm-game songs are only the first artifact type. Later:

- Jellyfin pulls movies and TV through firkin.
- A phone app lets you choose, from the desktop, which MP3s are pushed
  to the phone.

Media apps (Jellyfin, iTunes, ...) keep metadata in opaque databases,
so moving to a new computer means fixing metadata all over again.
firkin keeps metadata as plain YAML files next to the media, so moving a
library is an `rsync` or a `firkin` run.

## Decisions

### Naming and packaging

- **Project name:** firkin.
- **GitHub:** org https://github.com/firkin-media, repo
  `firkin-media/firkin`.
- **Licence:** MIT.
- **Rust crates:** use the `firkin-media` prefix. The bare `firkin`
  crate belongs to someone else, and no transfer will be requested.
- **CLI:** the `firkin-media-cli` crate installs the `firkin` binary.
- **URI schemes:** `firkin:` (registered by native apps with the OS) and
  `web+firkin:`. Browsers only let web pages register schemes with a
  `web+` prefix.
- **Extension:** catalog files use `.firkin`.

### Architecture

- **The `firkin` CLI is the integration contract** for host apps (see
  ADR 0001 below):
  - A host app runs `firkin` to search and to fetch, and reads progress
    as JSON lines on stdout.
  - Host apps embed no networking, BitTorrent, or client library.
  - Search goes through the CLI too. There is no server-side search API;
    firkin searches its local copies of catalogs.
- **A resident service is allowed later, behind the CLI.** The CLI may
  start handing work to a resident firkin service, or to an existing
  torrent client (e.g. through Transmission RPC), without host apps
  changing. Sharing (seeding) will need such a long-running process.
- **Language:** Rust.

### Catalog format

- **The catalog tree is the folder tree.**
  - Each folder has a catalog file that describes the media in that
    folder and references the catalogs of its subfolders.
  - Sharding a large catalog means splitting it into subfolders.
  - The same format serves as the per-folder metadata sidecar of a
    local library and as a published catalog.
  - Filename: `catalog.firkin` (*assumed; not yet confirmed*).
- **Encoding:** YAML.
  - *Proposed, not yet confirmed:* a strict subset.
    - YAML 1.2 core schema.
    - No anchors or aliases.
    - Strings for anything ambiguous, which avoids the "Norway problem"
      and `1.10` being parsed as a float.
- **Entries are polymorphic and typed:**
  - A **catalog reference** (`core/catalog@1`) has a `url` pointing to
    another catalog file.
  - An **artifact** of a media type (e.g. `rhythm-game/song@1`).
- **Relative URLs resolve against the file they appear in**, as in
  HTML. This applies both to catalog references and to an artifact's
  `urls`.
- **References can form cycles.** Following them requires cycle
  detection: a visited set of normalised URLs.
- **An artifact's files can be hosted or index-only, per artifact.**
  - Hosted: the files sit in the same root.
  - Index-only: the `urls` point elsewhere (an HTTP host, a torrent, a
    magnet link).

### Transports

- **A catalog is located by a URL whose scheme selects the transport:**
  - git over `https://` or `ssh://`
  - BitTorrent via `magnet:` or a `.torrent` URL
- **A `#path=` fragment locates the catalog file inside the transport
  root,** for example a path inside a torrent.
- **Git catalogs** are cloned and then fetched, so an update transfers
  only what changed. A catalog server is just a git repo on any git
  host; no server-side code is needed. A tarball or plain-HTTP catalog
  transport is not planned.
- **Torrents:**
  - A torrent is a firkin catalog only if it contains a catalog file.
    Torrents without one are not packs.
  - A torrent catalog is immutable. A new release is a new infohash,
    and so a new catalog.
  - One torrent can contain several catalog files, i.e. a sharded
    catalog.

### Identity

- **An artifact is identified by `{id, version, catalog, hash}`:**

  | Field | Meaning |
  |---|---|
  | `id` | UUIDv7. Identifies the work (e.g. the song) across all catalogs; the same `id` in two catalogs means the same work. |
  | `version` | UUIDv7. Identifies one release of it. UUIDv7s sort by time, so "latest" falls out of the ordering. |
  | `catalog` | The normalised URL of the transport root (git repo or torrent) the record came from. The catalog file's path within that root is not part of identity, so resharding doesn't change identities (*inferred from discussion; confirm*). |
  | `hash` | The content hash (below). |

- **Immutability is a convention, not a guarantee.** A published
  version should never change, but nothing can enforce that. That's why
  the catalog is part of identity.
- **When two catalogs publish the same `(id, version)`:**
  - With the same `hash`, they are mirrors of one release.
  - With different hashes, `catalog` tells them apart.
- **When the same `(id, version)` appears twice in one catalog:**
  - firkin warns and lists both, keyed by their hashes. An earlier
    "anchor" field was folded into the hash.
  - *Proposed, not yet confirmed:* records with the same `id`,
    `version` and `hash` describe the same files, so they merge, with
    their `urls` combined.
- **Grouping for display:** by `id`, then `version`, then `catalog`,
  then `hash`.
- **A record has two parts:**
  - an identifying part: `{id, version, hash}`, plus the implied
    `catalog`
  - a download part: `{urls: [...]}`

### Content hash

- **The hash covers the artifact's unpacked files, not an archive.**
  The same release delivered over HTTP or over a torrent therefore
  hashes the same.
- **Algorithm:**
  1. List each file as a line `<path>: sha256:<hex>`.
  2. Sort the lines bytewise (a precisely specified equivalent of
     `LC_ALL=C sort`).
  3. Take SHA-256 of the sorted listing.
- **Details still to confirm:**
  - Paths are relative to the artifact folder and use `/` as the
    separator.
  - Paths are normalised to Unicode NFC.
  - Paths containing a newline are rejected.
  - Every line ends with `\n`.
  - The final value is written as `sha256:<hex>`, so the algorithm can
    change later.
  - Excluded files:
    - the folder's own catalog file, so that editing metadata doesn't
      change identity
    - any install marker firkin writes
    - OS junk (`.DS_Store`, `._*`)

### Identifier string form

- **Fragment form:**
  ```
  <root-url>#path=<catalog-path>&id=<uuid>&version=<uuid>&hash=sha256:<hex>
  ```
  - Values are percent-encoded.
  - The fragment is never sent to a git server and is not part of a
    magnet link's meaning, so one rule works for every transport.
  - `path` only helps locate the record; it is not part of identity.
- **Scheme wrapper**, for OS and browser link handling:
  - `firkin:https://...#id=...`
  - `firkin:magnet:?xt=...#path=...&id=...`
  - `web+firkin:` the same way.
- **Partial forms are allowed for lookup.** For example,
  `<root-url>#id=<uuid>` means "latest version from this catalog".
- **Pins carry every key.**

### Selection, following, pinning

- **Every catalog reference is a selectable leaf, and starts
  unchecked.** This holds at every level of the tree, whether the
  reference points into the same root or to another root.
  - Its contents stay hidden until the user checks it.
  - References to other roots are not fetched at all until checked: no
    clone, no torrent swarm, without consent.
  - Example: a catalog listing both "pirated-music" and
    "open-source-music". The user checks only the second.
- **Selections are remembered.**
- **Users pin a specific artifact** (`id`, `version`, `catalog`,
  `hash`).
  - firkin tells them when an upgrade is available. It never switches
    on its own.
  - "Latest" (highest `version`) is only the default when picking.

### Artifact types

- **Type names have the form `<namespace>/<name>@<major>`.**
  - Example: `rhythm-game/song@1`.
  - The `core/` namespace is reserved. `core/catalog@1` is the catalog
    reference.
  - Other namespaces follow an open convention.
- **Every type carries the common fields** `id`, `version`, `hash`,
  `urls` and `title`.
- **Unknown types still work.** A firkin build that doesn't know a type
  can still list an artifact of that type by its common fields, and
  sync it.
- **Minor schema revisions only add optional fields,** so they don't
  appear in the type name.

### `rhythm-game/song@1`

These fields come on top of the common fields:

| Field | Contents |
|---|---|
| `artist`, `album`, `year`, `genre`, `language`, `duration` | For search and display. |
| `charts` | A list of `{format, parts, difficulties?}`, one per chart in the song. Details below. |
| `media` | Which of audio, video and cover art are included, so a notes-only song is visible before download. |
| `charter` | Credit for the chart author. |
| `license` | An SPDX identifier, where one applies. |

- **`format`** is one value from an open set listed in the type spec:
  `ultrastar-txt`, `fof-mid`, `clone-hero-chart`, `stepmania-sm`,
  `singstar-xml`, and so on.
- **`parts`** lists which instruments are charted: vocals, guitar,
  bass, drums, keys, dance, and so on.
- **What Performous plays** (upstream master 947b1be,
  `game/songparser.cc:77-92`): UltraStar `.txt`, Frets on Fire
  `song.ini` + `notes.mid`, StepMania `.sm`, SingStar `notes.xml`.
- **What Performous can't play:** Clone Hero `notes.chart`. That's why
  `charts` exists: a host app filters on the formats and parts it
  supports.

### Download unit

- **One artifact is one song (or movie, or track).** There are no pack
  downloads.
- **Why:** per-artifact entries let firkin download many artifacts
  concurrently, from different mirrors.
- **Large torrent packs are catalogs.** BitTorrent's per-file selection
  pulls just one artifact's folder.
- **Install location** (*assumed*): `<target-dir>/<id>/`.

### v1 scope

- **The spec is general:** typed artifacts, catalog references,
  sharing.
- **The v1 implementation is narrow:**
  - git catalogs, with HTTP(S) artifact downloads
  - the `rhythm-game/song@1` type
  - download only
- **Later:** BitTorrent and sharing/seeding.

## Open questions

- **CLI contract:** the command set (search, fetch, catalog
  management, status, upgrade check) and the JSON event schema for
  progress, completion and errors, including exit codes.
- **Install records:** where firkin records what it installed, and
  where it keeps selections and pins. The options are a separate
  marker file or the folder's catalog file itself.
- **Trust:** catalog trust and signing. Signed git commits are one
  option.
- **Prior art:** not yet surveyed. BEP 46 (mutable torrents via the
  DHT), IPFS/IPNS, Hypercore and Syncthing may already cover parts of
  the core.
- **Unconfirmed items:**
  - the `catalog.firkin` filename
  - the strict YAML subset
  - the content-hash details and exclusions
  - merging identical duplicates
  - catalog identity being the transport root
- **Artifact files in a folder:** whether a hosted artifact's files are
  "the folder containing its catalog file" or "whatever its `urls`
  point at". Also whether one catalog file may describe several
  artifacts inline, or only one artifact plus references.
- **Publish placeholders:** `firkin-media-cli` was not checked on
  crates.io. Placeholder releases of it and `firkin-media` should be
  published early to hold the names.

## Seed files

### `CONTEXT.md`

```md
# firkin

firkin knows all media, selectively syncs it to and from your machine,
and gives other apps a way to integrate with it.

## Language

### Catalogs

**Catalog**:
A tree of catalog files, published from one transport root, that
describes media artifacts and references other catalogs.
_Avoid_: index, server, feed

**Catalog file**:
One YAML file (`catalog.firkin`) describing the media in a folder and
referencing its subfolders' catalog files.
_Avoid_: manifest, sidecar (when meaning the format)

**Catalog reference**:
An entry of type `core/catalog@1` that points to another catalog file,
and that the user can select or leave unselected.
_Avoid_: link, subscription

**Transport root**:
The git repository or torrent a catalog file lives in. Its normalised
URL is the catalog part of an artifact's identity.
_Avoid_: origin, host

### Artifacts

**Artifact**:
One media item: a song, a movie, a track. It is the unit of selection,
download and identity.
_Avoid_: entry, item, pack

**Artifact type**:
A namespaced, major-versioned schema name such as `rhythm-game/song@1`.
_Avoid_: kind, profile

**Version**:
One release of an artifact, identified by a UUIDv7.
_Avoid_: revision, update

**Content hash**:
SHA-256 over the sorted listing of an artifact's files and their own
SHA-256s.
_Avoid_: checksum, infohash

### Use

**Pin**:
A user's choice of one exact artifact (id, version, catalog, hash),
kept until the user upgrades it.
_Avoid_: lock, subscription

**Host app**:
An application, such as Performous or Jellyfin, that uses media by
running the `firkin` CLI.
_Avoid_: client, consumer

## Relationships

- A **Catalog** belongs to exactly one **Transport root**, and contains
  one or more **Catalog files**.
- A **Catalog file** contains **Artifacts** and **Catalog references**.
- An **Artifact** has one id, one or more **Versions**, and one
  **Content hash** per version.
- The same **Artifact** id may appear in many **Catalogs**.
- A **Pin** names exactly one **Version** from one **Catalog**.

## Example dialogue

> **Dev:** "Two catalogs list the same song id and version. Do we show it twice?"
> **Domain expert:** "If the **Content hash** matches, they're mirrors of one **Version**; show it once with both sources. If the hashes differ, show both under that version, labelled by **Catalog**."

## Flagged ambiguities

- "client" meant both the `firkin` CLI and the app calling it.
  Resolved: the app is a **Host app**; firkin is firkin.
- "pack" meant both a bundle download and a torrent of many songs.
  Resolved: there are no pack downloads. A multi-artifact torrent is a
  **Catalog**.
```

### `docs/adr/0001-firkin-cli-is-the-contract.md`

```md
# Host apps shell out to the firkin CLI instead of embedding a library

Host apps (Performous first) integrate by running the `firkin` CLI for
search and download and reading its JSON-lines progress on stdout. They
do not link a client library. This keeps networking, BitTorrent, and
the legal surface of fetching content out of every app. It lets firkin
be written in Rust regardless of the host app's language and license,
and it lets firkin later hand downloads to a resident service or an
existing torrent client without host apps changing.

## Considered Options

- **Embedded client library**: rejected. Every host app would carry an
  HTTP stack, and possibly libtorrent, in its own language and build
  system. Performous has no HTTP client today.
- **Message queue to a resident downloader service as the contract**:
  not rejected outright, just kept behind the CLI. It needs an
  installed, running, discoverable service before a host app can do
  anything. The CLI can start delegating to such a service later, and
  sharing (seeding) will need one.
```

## Blocking

- `issues/issue-01a11320-c738-73f1-93c5-03781c77921e-performous-online-song-servers.md`
  (Performous embeds the `firkin` CLI)

## Origin

Split out of the Performous issue above on 2026-10-15. The full
question-and-answer history, including superseded answers, is in that
issue's Grill Log.
