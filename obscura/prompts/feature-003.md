# Fix: enable `stealth` mode as a supported default, and close its SSRF gaps

## Context [feature-003]

This fork intends to depend on `stealth` mode (the Cargo feature that swaps the
normal HTTP client for a browser-TLS/HTTP2-fingerprint-emulating client, used to
avoid anti-bot fingerprinting) as a core, load-bearing part of the project going
forward — not as an optional, rarely-used mode. Any gap that's acceptable to
leave in an optional feature is not acceptable here: this needs to be as safe as
the non-stealth path before it's relied on.

## Problem

With the `stealth` feature enabled, the stealth navigation code path
(`obscura-browser`'s page-fetch logic, when a stealth client is configured) uses
a completely separate HTTP client from the default path, and that client has no
SSRF protection at all:

- Main navigation via the stealth client performs no host/IP validation of any
  kind before dialing out — only an ad/tracker blocklist check, which is
  unrelated to SSRF. A page (or the operator) navigating to
  `http://169.254.169.254/latest/meta-data/iam/security-credentials/` or any
  RFC1918/loopback address succeeds and returns the body, with no equivalent of
  the "block private networks unless explicitly opted in" behavior the
  non-stealth path has.
- Scripted `fetch()`/XHR under stealth mode *does* call a URL validator, but that
  validator only checks the URL's literal host string (IP literals and the
  literal strings `localhost`/`127.0.0.1`/`::1`) — it does not resolve DNS. The
  underlying stealth HTTP client has no custom DNS resolver installed (unlike the
  non-stealth client, which plugs in an SSRF-guarding resolver that rejects any
  *resolved* address in a forbidden range). A hostname that isn't a literal IP
  but resolves to a private/loopback address — via attacker-controlled DNS, or a
  public wildcard-DNS convenience service that maps a hostname straight to an
  embedded IP — passes the literal-string check and reaches the internal address.

## Fix

1. Make the `stealth` feature straightforward to enable and treat it as a fully
   supported configuration, not an experimental opt-in with known gaps.
2. Add the same egress/SSRF protection to the stealth navigation path that the
   non-stealth path has: validate the target URL/resolved address before
   dialing out, respecting the same "block private/loopback/link-local ranges
   unless explicitly allowed" policy and the same opt-in flag used elsewhere in
   this project. Do this at the point where the stealth client is about to
   connect, not just at the call site that constructs the request — a redirect
   response received over the stealth client must be re-validated on every hop,
   the same way the non-stealth path already does.
3. For stealth `fetch()`/XHR: install a DNS-resolution-aware guard on the
   stealth HTTP client (equivalent to the resolver used by the non-stealth
   client), so a hostname resolving to a forbidden address is rejected even when
   its literal string isn't recognizably an IP or `localhost`. The literal-string
   check alone is insufficient and should be treated as a secondary check, not
   the primary defense.
4. Add regression tests covering: stealth navigation to a loopback/RFC1918
   literal IP (must be rejected by default), stealth navigation to a hostname
   that resolves to a private address (must be rejected by default), and the
   equivalent opt-in case succeeding when private-network access is explicitly
   allowed.

## Why this matters

Without this fix, turning on `stealth` — which this project plans to depend on
by default — silently drops the project's core egress-control guarantee for
every page it automates. A hostile page could use it to reach the automation
host's internal network or cloud-metadata endpoint, with nothing but ordinary
navigation or a `fetch()` call to a rebinding domain.
