# Docs: record the known-open, intentionally-unfixed findings in `SECURITY.md`

## Problem [feature-008]

An ad hoc security review of this fork surfaced several findings that are real
gaps in the upstream code but are not being fixed in this fork, because this
fork's maintainers embed the `obscura` library crate directly and do not
compile in or run `obscura-cli`, `obscura serve` (the CDP server), `obscura
mcp` (the MCP server), or the project's published Docker image. `SECURITY.md`
does not currently mention any of this — a reader has no way to know these
gaps exist, or that this fork's clean bill of health on them is conditional on
a specific way of consuming the project, not a general guarantee.

The findings in question:

1. **CDP WebSocket server has no Origin/Host validation** (any page open in a
   normal browser tab can open a WebSocket to `obscura serve` and issue
   arbitrary CDP commands — full remote-control takeover). Lives entirely in
   `crates/obscura-cdp`.
2. **MCP HTTP server defaults to open CORS with no authentication.** Lives
   entirely in `crates/obscura-mcp`.
3. **CDP page/session IDs are sequential rather than random**, which compounds
   finding 1 by making valid session IDs guessable once an attacker has any
   way to reach the server at all.
4. **The published Docker image runs as root by default**, which matters only
   to whoever runs that container image directly.

## Fix

Add a new section to `SECURITY.md` (a natural placement is right after
whatever section currently describes the project's threat model / what's
in-scope, so it reads as a continuation of that discussion rather than a
bolted-on afterthought) titled something like "Known issues not fixed in this
fork" or "Known issues, and why this fork doesn't need to fix them." For each
of the four findings above, state:

- What the gap is, in one or two sentences (no need to repeat full exploit
  detail — this is a security posture summary, not a vulnerability writeup).
- Which crate/binary/artifact it lives in (`obscura-cdp`, `obscura-mcp`, the
  Docker image).
- That this fork embeds the `obscura` library crate directly, which has no
  dependency on `obscura-cdp` or `obscura-mcp` and does not run the published
  Docker image — so none of this code compiles into or ships with this fork's
  actual use of the project, and the gap is not reachable in that
  configuration.
- An explicit, unambiguous warning that this reasoning does **not** extend to
  anyone who *does* use `obscura serve`, `obscura mcp`, `obscura-cli`, or the
  published Docker image — for those consumption paths, all four gaps above
  are real, unmitigated, and this fork has made no changes to address them.
  Don't let the surrounding "not applicable to us" framing read as "not
  applicable, period."

Keep this to a documentation change only — do not alter any code, CI
configuration, or the Docker image itself as part of this prompt. If a future
need arises to actually run `obscura serve`/`obscura mcp`/the Docker image,
that would be a new, separate piece of work with its own fix for these
findings, not a retroactive edit to this section.

## Why this matters

A `SECURITY.md` that's silent on known gaps reads as "no known gaps." Anyone
evaluating this fork — including a future maintainer of this same fork who
didn't do the original review — deserves an accurate, written record of what
was found, why it isn't fixed, and exactly where that reasoning stops applying,
rather than having to reconstruct it from a separate review document (or not
finding it at all).
