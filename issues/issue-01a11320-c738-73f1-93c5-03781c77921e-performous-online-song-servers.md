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

## Grill Log

### 2026-10-07

- Q: Which online source, and what counts as "a song" (USDB `.txt` charts only, charts plus yt-dlp media, CC archive packs from a curated index, or shell out to USDB Syncer)? — A: None of those as the core. Build an open, MIT-licensed song-distribution **protocol** with a reference server and a reference client; Performous embeds the client and is configured with a list of servers. Legality of content then sits with whoever runs a server, not with Performous or the protocol. The original inspiration was rhythmverse.co (https://rhythmverse.co/songfiles/game), not USDB.
- Q: Where does the protocol suite live: a standalone repo, inside the Performous fork, or inside nqaf? — A: A standalone component suite in a new repo, tentatively `github.com/earlye/rg-song-finder`; the final name is still open. Performous embedding the client becomes an nqaf fork feature for `performous`.
- Q: Does a server host song files, or only index pointers to them? — A: Either, decided per entry. The reference implementation supports both hosted files and index-only entries pointing elsewhere. Index-only entries may also be torrent files or magnet links. (This connects to upstream performous issue #4, "Content distribution over torrent".)
- Q: Which download types (HTTP(S), `.torrent`, magnet) must every client support? Should the game embed BitTorrent? — A: Neither question applies anymore. Downloading moves out of the game entirely; see the next answer.
- Q: How does a game use the client: embedded library, shell-out CLI, or messages to a resident downloader service? — A: The **fetcher CLI** is the contract games depend on. The game runs it (e.g. `rgsf fetch <entry> --into <songs-dir>`) and reads progress as JSON lines on stdout. The reference CLI can download by itself at first and later hand off to a resident service or an existing torrent client (e.g. Transmission RPC) without games changing. The game embeds no networking, so supported download types are up to the fetcher. The fetcher is written in Rust.
- Q: Does search also go through the CLI, or does the game query catalog servers directly? — A: Through the CLI (e.g. `rgsf search ... --json`). Performous needs no HTTP client.
- Q: What do we call the three roles? — A: **catalog server**: answers searches and lists download options. **fetcher**: the standalone CLI (or service behind it) that searches and downloads. **host game**: Performous or any other game that shells out to the fetcher. Avoid "client", since both the fetcher and the host game are clients of something.
