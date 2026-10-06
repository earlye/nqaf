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
