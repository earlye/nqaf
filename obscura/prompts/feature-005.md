# Fix: cookie `Domain` attribute accepted for shared multi-label public suffixes

## Problem [feature-005]

`obscura-net`'s cookie jar correctly rejects a `Set-Cookie` response trying to
scope a cookie to a bare single-label suffix (e.g. a response can't set
`Domain=com`), and correctly rejects the classic single-label cross-domain
plant (one site setting a cookie that would be sent to an unrelated site
sharing only a TLD). What it does not do is consult a public suffix list for
multi-label public suffixes: its own code comment acknowledges that a full
public suffix list isn't bundled, so domains like `co.uk`, `github.io`,
`herokuapp.com`, or `vercel.app` are not recognized as "this is itself a
registrable-boundary suffix, not a single organization's domain."

Concretely, a response from `attacker.github.io` can set
`Set-Cookie: sid=x; Domain=github.io`, and the domain-matching logic will then
send that cookie to every other `*.github.io` site the automation visits —
tenants of the same shared-hosting suffix that have nothing to do with each
other. The same applies to any other multi-label public suffix not covered by
the current domain/dot-boundary check.

## Fix

Bundle a public suffix list (the standard one is Mozilla's Public Suffix List,
available as a data file or via an existing Rust crate that wraps it) and
consult it when validating a `Set-Cookie` response's `Domain` attribute: reject
`Domain` values that are themselves a public suffix (exactly matching an entry
in the list), the same way a bare TLD is already rejected today — this is the
same check, just with a real suffix list instead of only catching the
single-label case.

Prefer an existing, actively-maintained crate that already embeds/updates the
public suffix list over hand-rolling one, since the list itself changes over
time and reimplementing its parsing/update logic is unnecessary maintenance
burden for this project.

Add regression tests: a `Set-Cookie: ...; Domain=github.io` response from
`attacker.github.io` must be rejected (or downgraded to a host-only cookie
scoped just to `attacker.github.io`, matching how browsers actually handle
this case, rather than silently dropped) — confirm which behavior matches
what the existing single-label-suffix-rejection test already asserts, and be
consistent with it. Also test that an ordinary two-label domain like
`Domain=example.com` (not a public suffix) is still accepted normally, to
confirm the fix doesn't overreach.

## Why this matters

Without this, a page hosted on any shared-hosting platform can plant cookies
that get sent to every other unrelated tenant on that same platform that the
automation subsequently visits — a real cross-origin cookie/session leak
between sites that consider themselves, and are, completely separate.
