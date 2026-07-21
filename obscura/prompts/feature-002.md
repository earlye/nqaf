# Fix: SSRF bypass via ES module dynamic `import()` / `<script type=module>`

## Problem [feature-002]

`obscura-net` protects against SSRF (a page reaching loopback/RFC1918/link-local/
cloud-metadata addresses) via a custom DNS resolver (something like
`SsrfGuardResolver`) plugged into the HTTP client, plus a literal-host check
(`validate_url`/`validate_fetch_url`) that runs before the request is sent. This
works correctly for ordinary navigation and for `fetch()`/XHR initiated from page
JavaScript.

It does **not** work for ES module loading. The module loader (in `obscura-js`,
the code that implements dynamic `import()` and `<script type="module">`) builds
its own HTTP client and fetches the module source directly, with no call to
`validate_fetch_url`/`validate_url`/an IP-forbidden-range check anywhere in that
file. Its only protection is the DNS-resolver-level guard on the underlying HTTP
client — and the HTTP client library in use skips the custom DNS resolver
entirely whenever the target host is already a literal IP address (this is
documented/expected behavior of the underlying connector: if the host string
parses as an IP, there's nothing to resolve, so the resolver is never invoked).

Net effect: a page running
`import('http://127.0.0.1:6379/').catch(()=>{})` or
`<script type="module" src="http://169.254.169.254/latest/meta-data/iam/security-credentials/">`
reaches loopback/link-local addresses directly, because (a) the module loader
never checks the URL itself, and (b) the DNS-resolver-based guard it's implicitly
relying on doesn't fire for literal IP hosts.

## Fix

Add an explicit URL validation call in the module loader, at the point where it
is about to fetch a module's source, using the same validator function
(`validate_url`/`validate_fetch_url` or whatever it has been refactored into) that
already protects `fetch()`/XHR and navigation. This should not depend on the HTTP
client's DNS resolver as the only line of defense — validate the URL explicitly,
the same way the other two call sites do, so protection doesn't depend on
happening to route through a resolver that gets bypassed for IP literals.

Also verify: does the *DNS-resolver-based* guard on the shared HTTP client
correctly handle a hostname that resolves to a forbidden address, given the
resolver-skipped-for-IP-literals gap identified above? If the literal-IP
bypass affects any other caller of that HTTP client (not just the module
loader), fix it at the client-construction level too — e.g. by validating the
literal-IP case explicitly before ever handing the URL to the client, rather
than relying solely on the resolver hook.

Add a regression test that attempts to dynamically import a module from a
loopback/private-IP URL and asserts the import is rejected before any network
request is made.

## Why this matters

This is a silent, complete bypass of the project's SSRF protection through a
JS-reachable code path (dynamic `import()`) that most reviewers wouldn't think
to check separately from `fetch()`/XHR, since it looks like "just another way
to load a URL" but has its own, unguarded fetch implementation. A page can use
it to reach internal services, cloud metadata endpoints, or anything else on
the host's local network, with no special access beyond running JavaScript
that the automation already executes as a matter of course.
