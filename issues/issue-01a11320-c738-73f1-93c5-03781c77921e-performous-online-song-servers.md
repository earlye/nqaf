# performous: search and download songs from online song servers

## Context

Wanted: Performous can search online song servers and download songs
from them, instead of the user finding song packages and copying them
into a songs directory by hand.

Performous is tracked in nqaf: upstream `performous/performous`
(`performous/upstream.txt`), fork `earlye-forks/performous`
(`performous/fork.txt`). Fork features are written as prompts under
`performous/prompts/`; `feature-000` (README fork notice) and
`feature-001` (fork-local macOS DMG workflow) exist so far. This would
likely land as a new feature prompt there.

Not yet decided: which song servers to support, how search and download
appear in the UI, and where downloaded songs are stored.

## Relevant files

- `performous/prompts/feature-000.md`, `performous/prompts/feature-001.md` — existing fork feature prompts; a new one would follow their shape
- `performous/upstream.txt`, `performous/fork.txt` — the upstream and fork repos

## Draft ADR for the new repo

To be copied to `docs/adr/0001-fetcher-cli-is-the-contract.md` in the protocol suite repo once it exists.

```md
# Host games shell out to the fetcher CLI instead of embedding a library

Host games (Performous first) integrate by running the fetcher CLI for
search and download and reading its JSON-lines progress on stdout. They
do not link a client library. This keeps networking, BitTorrent, and the
legal surface of fetching content out of every game. It lets the fetcher
be written in Rust regardless of the game's language and license, and it
lets the fetcher later hand downloads to a resident service or an
existing torrent client without games changing.

## Considered Options

- **Embedded client library**: rejected. Every game would carry an HTTP
  stack, and possibly libtorrent, in its own language and build system.
  Performous has no HTTP client today.
- **Message queue to a resident downloader service as the contract**:
  not rejected outright, just kept behind the CLI. It needs an installed,
  running, discoverable service before a game can do anything. The CLI
  can start delegating to such a service later.
```

## Grill Log

### 2026-10-07

- Q: Which online source, and what counts as "a song" (USDB `.txt` charts only, charts plus yt-dlp media, CC archive packs from a curated index, or shell out to USDB Syncer)? — A: None of those as the core. Build an open, MIT-licensed song-distribution **protocol** with a reference server and a reference client; Performous embeds the client and is configured with a list of servers. Legality of content then sits with whoever runs a server, not with Performous or the protocol. The original inspiration was rhythmverse.co (https://rhythmverse.co/songfiles/game), not USDB.
- Q: Where does the protocol suite live: a standalone repo, inside the Performous fork, or inside nqaf? — A: A standalone component suite in a new repo, tentatively `github.com/earlye/rg-song-finder`; the final name is still open. Performous embedding the client becomes an nqaf fork feature for `performous`.
- Q: Does a server host song files, or only index pointers to them? — A: Either, decided per entry. The reference implementation supports both hosted files and index-only entries pointing elsewhere. Index-only entries may also be torrent files or magnet links. (This connects to upstream performous issue #4, "Content distribution over torrent".)
- Q: Which download types (HTTP(S), `.torrent`, magnet) must every client support? Should the game embed BitTorrent? — A: Neither question applies anymore. Downloading moves out of the game entirely; see the next answer.
- Q: How does a game use the client: embedded library, shell-out CLI, or messages to a resident downloader service? — A: The **fetcher CLI** is the contract games depend on. The game runs it (e.g. `rgsf fetch <entry> --into <songs-dir>`) and reads progress as JSON lines on stdout. The reference CLI can download by itself at first and later hand off to a resident service or an existing torrent client (e.g. Transmission RPC) without games changing. The game embeds no networking, so supported download types are up to the fetcher. The fetcher is written in Rust.
- Q: Does search also go through the CLI, or does the game query catalog servers directly? — A: Through the CLI (e.g. `rgsf search ... --json`). Performous needs no HTTP client.
- Q: What do we call the three roles? — A: **catalog server**: answers searches and lists download options. **fetcher**: the standalone CLI (or service behind it) that searches and downloads. **host game**: Performous or any other game that shells out to the fetcher. Avoid "client", since both the fetcher and the host game are clients of something.
- Q: Does a catalog server serve a static index, a dynamic search API, or both? — A: A static index only, structured so it can be sharded. The fetcher searches its local copy. No search API in v1.
- Q: How is the index served? — A: Over git. The fetcher clones each catalog and fetches updates, so an update only transfers what changed, and a catalog server is just a git repo on any git host. Git is the only transport; a tarball or plain-HTTP alternative is not expected ever to be needed.
- Q: What is the index layout? — A: `catalog.json` (format version, server metadata) plus numbered JSONL shard files, one catalog entry per line. Rejected: one file per entry, because of the filesystem overhead. JSONL also lets `grep` and `jq` serve as the first support tooling.
- Note: the fetcher CLI has no name yet. `rgsf` in earlier answers was a placeholder the agent made up from `rg-song-finder`.
- Q: How are entries assigned to shards, and how are edits and deletions handled? — A: The protocol doesn't mandate it; that's the catalog maintainer's call. The recommended practice is to append new entries to the highest-numbered shard, start a new shard at a size cap, edit lines in place, and delete by removing the line. So the fetcher must not assume which shard an entry is in.
- Q: What identifies an entry? — A: A UUIDv7, unique across the whole catalog and never reused.
- Q: What happens if an entry ID appears twice in one catalog? — A: The fetcher warns, and the newer entry wins. (What "newer" means is the next question.)
- Q: What does one download deliver: a single song, or a pack of many? — A: Only single songs. One entry is one song. Packs as single downloads are rejected: per-song entries let the fetcher download many songs at once, from different mirrors, rather than pulling one big archive.

### 2026-10-14

- Q: When an ID is duplicated, what does "newer" mean: position in the shards, an update timestamp, or a revision counter? — A: An update timestamp. Every record has at least `{"id": <uuidv7>, "last-update": <ISO 8601 timestamp>, ...}`, and the larger `last-update` wins.
- Pivot (replaces the `last-update` answer above and the earlier "duplicate ID warns, newer wins" answer): there is no "newer wins". Records are **versions**. A record is at least `{"id": <uuidv7>, "version": <uuidv7>, ...}`. `id` identifies the song; `version` identifies one release of it. Every version of a song is visible to the user, whether it comes from the same catalog or from different ones, and the user picks. The same `id` in different catalogs means the same song. If two catalogs publish the same `(id, version)` with different contents, the catalog is added to the key to tell them apart.
- Q: Is a published version immutable? — A: Ideally, but nothing can enforce that. So the catalog a record comes from is an implied part of its identity.
- Q: Does the fetcher switch to the latest version automatically? — A: No. Users pin a specific song, version and provenance, and are told when an upgrade is available. "Latest" is only a default for picking.
- Q: What if the same `(id, version)` appears twice in one catalog? — A: Warn and list both. The full identifier is `{id, version, catalog, anchor}`, where `anchor` is like the `#fragment` of a URL and tells otherwise identical records apart. The UI groups entries by id, then version, then catalog, then anchor if needed.
- Q: How does the fetcher tell that two catalogs disagree about a version's contents? — A: Every record carries a content hash. A record's identifying part is `{id, version, catalog, anchor, hash}`; its download part is `{..., urls: [...]}`. What exactly the hash covers is still open.
- Q: Does the content hash cover the archive or the unpacked song files? (A torrent's file tree is fixed by the torrent, so there may be no single archive to hash, and an infohash would make the same release over HTTP and over torrent look different.) — A: The unpacked song files. A torrent only counts as a rhythm-game pack if it contains a catalog file; torrents without one are not packs. So a torrent can itself be a catalog, addressed as `{magnet-url}#{path-in-torrent-to-catalog}`.
- Q: Is git the only catalog transport, given torrents can now be catalogs? — A: No; the earlier "git only" answer is restated. A catalog is identified by a URL whose scheme picks the transport (git over `https://` / `ssh://`, or `magnet:` / `.torrent`), with a `#fragment` giving the catalog file's path inside it. `catalog` in the identifier is this URL, normalised. A torrent catalog can never change; a new release is a new infohash, which is a new catalog.
- Q: Do torrent catalogs use the same layout as git catalogs, and what is the file format? — A: The same format everywhere, and it is JSONL with a `.jsonl` extension. The earlier `catalog.json` + numbered shards answer is replaced. Catalog entries are polymorphic: `{"type": "song", "id": ..., ...}` or `{"type": "catalog", "url": ..., ...}`. A catalog entry references another catalog file, either relative (`./shard-n.jsonl`, which is how sharding works) or absolute (e.g. a magnet URL). One torrent can therefore hold several shards. Following references requires cycle detection.
- Q: Do relative URLs, including in song `urls`, resolve against the file they appear in? — A: Yes, exactly.
- Q: How is the anchor derived: content hash first, position as a fallback? — A: No position fallback; resharding is too likely. The anchor is the content hash.
- Q: How exactly is the content hash computed? — A: List each unpacked song file as `<path>: sha256:<hex>`, sort the lines (bytewise, a precisely defined equivalent of `sort`), and take SHA-256 of the sorted listing. That result is the song's hash.
- Reframe (raised by the user): this is more accurately a **selective media library synchronizer for p2p networks**. A catalog is a tree: catalog files list other catalog files and their versions, and the leaves are media artifacts. A rhythm-game song is the first leaf type; a remote catalog reference is another. The processor pulls referenced catalogs, lists the media artifacts available remotely and locally, makes remote artifacts available locally, and can optionally share them.
- Q: Does the syncer follow catalog references to other roots automatically? — A: Yes, always.
- Q: How much of the general system is built before Performous gets anything? — A: General spec, narrow v1. The spec covers typed artifacts, catalog references and sharing. v1 implements git/HTTP transports, the rhythm-game song artifact type, and download only; torrent and sharing come later.
- Vision (context for scope, not v1): Jellyfin pulls movies and TV through this; a phone app lets you pick on your desktop which MP3s to push to the phone. Aside from the user: Jellyfin server needs a Rust reimplementation. `syncer` is a placeholder name; the user will pick a better one.
- Proposed pivot (open): replace `catalog.jsonl` with `catalog.mdf` ("metadata file" / "media data format"), a YAML schema describing the media in a given folder. Motivation: Jellyfin, iTunes and similar keep metadata in opaque databases, so moving to a new computer means fixing metadata again. With plain YAML next to the media, moving is an `rsync`, or a run of the syncer.
- Q: Is `catalog.mdf` both the per-folder sidecar and the published catalog format (the catalog tree follows the folder tree), or are per-folder YAML sidecars compiled into a separate JSONL index? — A: One format. The `catalog.mdf` pivot is accepted and replaces JSONL. Sharding is subfolders. Proposed by the agent and not yet confirmed: exclude the folder's own catalog file (and any syncer marker) from the content hash, so metadata edits don't change a song's identity; restrict YAML to a strict subset (1.2 core schema, no anchors or aliases, strings for anything ambiguous).
- Q: (Revisited) Does the syncer follow references to other roots automatically? — A: Not always; the earlier "always" answer is revised. References to other roots *may* be followed, as the user directs. Example: a catalog containing both "pirated-music" and "open-source-music" references; the user follows the second and not the first.
- Q: File extension, given `.mdf` is already used by SQL Server data files, disc images and ASAM MDF? — A: Leaning toward `.yameta` or similar; the 3-character limit is not a constraint. Not final.
- Q: What does following a reference mean, and what's the default? — A: A catalog reference is a selectable leaf, like a song, at every level of the tree and whether it points to the same root or another one. It starts unchecked, and its contents aren't visible until the user checks it (e.g. an unchecked "pirated-music" stays closed). Other-root references aren't fetched at all until checked, so there's no clone and no swarm without consent. Selections are remembered.
- Q: How are artifact types named and versioned? — A: Namespaced and versioned, in the short form `<namespace>/<name>@<major>` (e.g. `rhythm-game/song@1`), with reserved namespaces for core types (the catalog reference leaf is `core/catalog@1`) and an open convention for everyone else. A syncer that doesn't know a type still lists it by the common fields every type has (`id`, `version`, `hash`, `urls`, a display `title`) and can sync it without understanding it. Minor schema changes add optional fields only and don't appear in the type name.

### 2026-10-15

- Q: What fields does `rhythm-game/song@1` carry so a host game can filter for songs it can play? — A: Beyond the common fields: `artist`, `title`, `album`, `year`, `genre`, `language`, `duration`; `charts`, a list of `{format, parts, difficulties?}`, where `format` is one of an open set listed in the type spec (`ultrastar-txt`, `fof-mid`, `clone-hero-chart`, `stepmania-sm`, `singstar-xml`, ...) and `parts` covers vocals, guitar, bass, drums, keys, dance, ...; `media` (which of audio, video and cover art are included); `charter`; `license` (an SPDX identifier where one applies).
- Q: What is the string form of an artifact identifier? — A: The fragment form: `<root-url>#path=<catalog-path>&id=<uuid>&version=<uuid>&hash=sha256:<hex>`, with values percent-encoded. The fragment is never sent to a git server and isn't part of a magnet link's meaning, so one rule covers git, magnet and `.torrent` roots. `path` only helps locate the record and isn't part of identity. Partial forms are allowed for lookup (e.g. `<root-url>#id=<uuid>` means the latest version from that catalog); pins carry every key. For OS and browser link handling, a custom-scheme wrapper goes in front: `<scheme>:https://...#id=...` or `<scheme>:magnet:?xt=...#path=...&id=...`. The scheme name is pending the project name.
- Q: What is the project called? (Detour; candidates checked against crates.io, GitHub, IANA and notable products: larder, medialoom, yameta, ferro, ferrum, ferra, ferrarum, ferri, ferrata, ferreus, ferry, skiff, junk, amphora, lading, firkin, hogshead, cask, bale.) — A: **firkin**. Rust crates use the `firkin-media` prefix (the bare `firkin` crate is a small containerization library; no transfer will be requested). `firkin-media-cli` installs the `firkin` binary. URI schemes are `firkin:` and `web+firkin:` (browsers only allow web pages to register `web+`-prefixed schemes). The file extension is `.firkin`. GitHub org: https://github.com/firkin-media, which replaces the tentative `earlye/rg-song-finder`. "Fetcher" / "syncer" in earlier answers now means `firkin`.
- Q: Keep grilling here, or consolidate and split the firkin design out of this Performous issue? — A: Consolidate and split. The firkin design gets its own document, to seed the repo `firkin-media/firkin`. This issue narrows to "Performous embeds the `firkin` CLI", blocked by firkin v1. Overall view of firkin: "an app that knows all media, selectively syncs it to/from your machine, and provides an integration mechanism for other apps."
