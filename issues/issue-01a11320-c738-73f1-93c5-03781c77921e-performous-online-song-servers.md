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
