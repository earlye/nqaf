# Fix: page-triggered navigation can read local files regardless of `allow_file_access`

## Problem [feature-001]

`BrowserContext` (in the `obscura-browser` crate) has an `allow_file_access: bool`
field, defaulting to `false`, that is supposed to prevent a page from causing a
`file://` URL to be read. In practice this flag is consulted in exactly one place:
the CDP command handlers for `Page.navigate` and `Target.createTarget` (in the
`obscura-cdp` crate). It is never read anywhere in `obscura-browser` or
`obscura-net`.

The actual network-layer URL validator (`validate_url`, in `obscura-net`'s HTTP
client module) allows the `file` scheme through unconditionally:

```rust
if scheme == "file" || allow_private_network {
    return Ok(());
}
```

So any navigation that reaches this validator through a path other than the CDP
`Page.navigate` command bypasses the file-access gate entirely. Concretely: when a
page's own JavaScript sets `location.href`, submits a form, or a user clicks a
link, that queues a "pending navigation" on the `Page` object (in
`obscura-browser`). The next time the page is polled/ticked (e.g. after
`Runtime.evaluate`, after a simulated click, or in the plain library-embedding API
whenever pending navigations are processed), that pending navigation is drained
and executed directly against the HTTP client — going straight through
`validate_url` with no `allow_file_access` check anywhere on that path.

This means: a page being automated with `<a href="file:///etc/passwd">` — clicked
via the ordinary, ubiquitous "dispatch a click" mechanism every automation
framework uses — causes the local file to be fetched and its bytes to come back
as the response body, indistinguishable from a normal HTTP response, regardless
of `allow_file_access`'s value. This is not a CDP-specific bug: it reproduces
through the plain Rust embedding API (`obscura` crate) with no CDP server
involved at all.

## Fix

Move the file-access gate down to where the actual fetch decision is made, so
every code path that can initiate a navigation or a `file://` fetch enforces it
consistently — not just the one CDP command handler. Concretely:

- Thread `allow_file_access` (or an equivalent capability) through to
  `obscura-net`'s URL validator itself, so `validate_url` (or whatever function
  owns the "is this scheme/host allowed" decision) rejects `file://` by default
  and only allows it when the context that initiated the fetch was explicitly
  constructed with file access enabled.
- Make sure this applies uniformly regardless of *how* the navigation was
  triggered — a CDP `Page.navigate` command, a page's own `location.href`
  assignment, a link click, a form submission, and an HTTP redirect chain must
  all be checked identically. Do not special-case any one of these; the bug
  today is exactly that only one entry point (the CDP command handler) has the
  check.
- Once the check lives in the shared validator, the CDP-layer check in
  `Page.navigate`/`Target.createTarget` becomes redundant — you can leave it as
  defense-in-depth or remove it, but the shared validator must be the source of
  truth so the plain library-embedding API is protected without any CDP code
  being involved.
- Keep the default `false` (file access denied unless explicitly opted into),
  matching the existing `allow_file_access` default.
- Add a regression test that: (a) constructs a context/page with the default
  (file access disabled), (b) triggers navigation to a `file://` URL via the
  *page-triggered* path (i.e. via whatever internal mechanism handles
  `location.href`/link-click navigation, not the CDP command), and (c) asserts
  the navigation is rejected. Also add a matching test that a context
  explicitly constructed with file access enabled succeeds, to confirm the
  opt-in still works.

## Why this matters

This defeats the one protection this project has against a hostile page reading
the local filesystem of whatever machine is running the automation, using
nothing more exotic than a link click or a JS redirect — exactly the kind of
interaction any browser automation performs constantly against untrusted sites.
It requires no CDP access, no special flags, and no attacker sophistication
beyond getting a `file://` link or redirect into a page the automation visits.
