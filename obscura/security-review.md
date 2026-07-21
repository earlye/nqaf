# Obscura Security Review

Tracking doc for an ad hoc security review of https://github.com/h4ckf0r0day/obscura
(this fork). Findings come from a set of parallel focused code reviews, cross-checked
against the project's own `SECURITY.md` threat model. This file is the running record
so we can go through findings one at a time instead of all at once.

## Your use case (scopes everything below)

You're embedding the `obscura` library crate directly inside your own Rust process to
drive deterministic website automation. You are **not** running `obscura serve` (the
CDP server) or `obscura mcp` (the MCP server) — those are separate binaries/subcommands
of `obscura-cli`. This matters a lot for prioritization, see below.

### What is CDP?

CDP (Chrome DevTools Protocol) is the JSON-RPC-over-WebSocket protocol Chrome/Chromium
expose for remote control: DevTools itself, Puppeteer, Playwright, and Lighthouse all
drive a browser through it — navigate pages, evaluate JS, inspect/mutate the DOM,
intercept network traffic, take screenshots, etc. Obscura implements a CDP-compatible
server (`obscura serve`, `crates/obscura-cdp`) so existing Puppeteer/Playwright code can
point at it as a drop-in replacement for headless Chrome.

### Can CDP / MCP be disabled or left out?

Better than disabled — **left out entirely at compile time**, and this happens
automatically with how you're using it:

- `crates/obscura` (the public embedding crate, `default = ["api"]`) depends only on
  `obscura-browser`, `obscura-net`, and `tokio`. It has **no dependency on
  `obscura-cdp` or `obscura-mcp`** — confirmed by reading `crates/obscura/Cargo.toml`
  and grepping the workspace for who depends on those two crates (only
  `obscura-cli` and, for MCP, `obscura-mcp` itself do).
- CDP and MCP code only exists in the `obscura-cdp` / `obscura-mcp` crates, wired up
  only by the `obscura-cli` binary's `serve` and `mcp` subcommands
  (`crates/obscura-cli/src/main.rs:60-186`). Neither crate exposes a Cargo feature on
  `obscura`/`obscura-browser` that would pull this code in — it's just not reachable
  unless you literally depend on `obscura-cli`, `obscura-cdp`, or `obscura-mcp`.
- There's no fine-grained "disable this one CDP domain" or "disable this one MCP tool"
  knob within those servers either (all-domains-or-nothing), but that's moot for you
  since you won't compile them in at all.

**Net effect: by depending only on the `obscura` crate, none of the CDP/MCP server
code — including the WebSocket-auth and CORS/auth gaps described below — ships in your
binary at all.** I'm marking those findings "not applicable to your use case" rather
than deleting them, in case that changes later (e.g. if you ever add a debug/inspection
server for your own tooling).

### Findings status legend

- **Applies** — reachable through the plain `obscura` library API, relevant to you.
- **N/A (CDP/MCP-only)** — lives entirely in code you don't compile in.
- **Applies if `stealth` feature enabled** — only matters if you turn on the `stealth`
  Cargo feature / `--stealth` equivalent in the embedding API. *Need to confirm: do you
  use it?*

## Unsafe block inventory

Scoped to what actually ships in your binary: excludes `obscura-cli`, `obscura-cdp`,
`obscura-mcp` (all N/A per the compile-time boundary above). That leaves **6 `unsafe`
blocks total**, all reachable from the plain `obscura` embedding API (3 directly in
`obscura`, 3 transitively via `obscura-dom`). Nothing in `obscura-browser`, `obscura-js`,
or `obscura-net` uses `unsafe` at all. Logged individually below with what safe-code
replacement would take — no fixes applied yet.

### U1: `crates/obscura/src/page.rs:156` — `Element::text()`
```rust
let page = unsafe { &mut *(self.page as *mut Page) };
```
**Why it's unsafe today:** `Element` stores `page: *const Page`, a raw pointer with no
lifetime tying it to the `Page` it was created from (see finding #11). `text()` takes
`&self` but needs `&mut Page` to call `page.evaluate(...)`, so the raw pointer is cast
away and dereferenced as mutable with nothing enforcing the pointer still points at a
live, uniquely-owned `Page`.

**Recommended safe replacement: `Weak<RefCell<InnerPage>>`.** Change
`Page { inner: InnerPage }` to `Page { inner: Rc<RefCell<InnerPage>> }`, and give
`Element` `page: Weak<RefCell<InnerPage>>` (created via `Rc::downgrade(&page.inner)`).
`text()`/`attribute()`/`click()` become:
```rust
let strong = self.page.upgrade().ok_or(Error::PageDropped)?;
let mut inner = strong.borrow_mut();
inner.evaluate(...)
```
This beats the two alternatives considered along the way:
- A lifetime-bound `Element<'a> { page: &'a mut Page }` (the first sketch) removes the
  unsafe block too, but forces callers to drop every `Element` before calling
  `page.goto()`/any other `Page` method — the compiler enforces it, but it's a real
  ergonomic constraint.
- A generational handle (`Element { node_id, epoch: u64 }`, `Page` tracking a bumped
  `epoch`) removes the lifetime constraint, but a per-`Page` epoch starting fresh isn't
  unique across `Page` instances — `Page1` and `Page2` can land on the same epoch value
  and an `Element` from one could pass validation against the other. Fixing that needs
  either a composite `(page_id, epoch)` key or folding page-identity into one shared
  global counter — extra state either way.

`Weak` sidesteps both: `Weak::upgrade()` returns `None` once `Page` is dropped (no
dangling deref, matching finding #11's UAF concern), and because a `Weak` is tied to one
specific `Rc` allocation rather than a numeric id, `Page1`'s `Weak` can *never* upgrade
to `Page2`'s `Rc` — there's nothing to compare, so the cross-page confusion case is
structurally impossible rather than merely checked. It also survives `Page` being
*moved* (not just kept alive), since the `Rc`/`Weak` point at the heap allocation, not
at `Page`'s own stack address. No global registry, no `Drop`-based cleanup — the
refcounting *is* the bookkeeping. This can be done entirely inside
`crates/obscura/src/page.rs`; `obscura-browser`'s `InnerPage` is untouched.

**Open verification item:** this assumes `Rc` (not `Arc`) is fine, i.e. that `Page` was
never meant to be `Send`. `InnerPage` holds `pub js: Option<ObscuraJsRuntime>`
(`obscura-browser/src/page.rs:169`), which wraps a V8 isolate — V8 isolates are
inherently `!Send`, and `obscura-cli` already runs a `current_thread` tokio runtime
(`main.rs:284`), consistent with `Page` never being `Send` today. Should be confirmed
with a one-line compile check (`fn assert_send<T: Send>(){} assert_send::<obscura::Page>();`
in a scratch test) before implementing — if it somehow already compiles, use
`Arc<tokio::sync::Mutex<InnerPage>>` instead (same shape, avoid a plain
`std::sync::Mutex` here since some `Page` methods `.await` while presumably needing the
lock held).

### U2: `crates/obscura/src/page.rs:166` — `Element::attribute()`
```rust
let page = unsafe { &mut *(self.page as *mut Page) };
```
Same root cause and same fix as `text()` above — this is the same pattern repeated
per-method, so a single `Element`/`Page` restructuring (`Weak<RefCell<InnerPage>>`)
fixes all three call sites at once.

### U3: `crates/obscura/src/page.rs:176` — `Element::click()`
```rust
let page = unsafe { &mut *(self.page as *mut Page) };
```
Same root cause and same fix as `text()`/`attribute()`.

### U4: `crates/obscura-dom/src/tree_sink.rs:18` — `ObscuraElemName::fmt` (Debug)
```rust
let name = unsafe { &*self.name };
```
**Why it's unsafe today:** `elem_name()` (`tree_sink.rs:48-62`) borrows the DOM arena
via `RefCell::borrow()`, extracts a raw pointer to a `QualName` living inside the arena,
then throws away the actual `Ref` and keeps only a type-erased `Ref<'a, ()>`
(`Ref::map(borrow, |_| &())`) purely so the `RefCell`'s runtime borrow-count stays
incremented — a concurrent `borrow_mut()` elsewhere would panic instead of aliasing, but
nothing statically ties `self.name`'s validity to that guard.
**What safe replacement requires:** keep the `Ref` mapped all the way down to the actual
field instead of erasing it: `Ref::map(borrow, |b| match &b.nodes[target.index()] {
Some(node) => match &node.data { NodeData::Element { name, .. } => name, _ => panic!() },
None => panic!() })`, producing a `Ref<'a, QualName>`. Store that directly as
`ObscuraElemName<'a> { name: Ref<'a, QualName> }` and implement `Debug`/`ns()`/
`local_name()` via ordinary `Deref` (`&self.name`, `&self.name.ns`, `&self.name.local`).
No raw pointer, no type erasure — `Ref::map` already exists precisely for "borrow a
sub-field and keep the runtime borrow-check alive" and is fully safe.

### U5: `crates/obscura-dom/src/tree_sink.rs:25` — `ObscuraElemName::ns()`
```rust
unsafe { &(*self.name).ns }
```
Same root cause and same `Ref::map`-based fix as line 18 — one struct change
(`name: Ref<'a, QualName>`) removes all three unsafe blocks in this file together.

### U6: `crates/obscura-dom/src/tree_sink.rs:29` — `ObscuraElemName::local_name()`
```rust
unsafe { &(*self.name).local }
```
Same root cause and same fix as lines 18/25.

**Net remediation scope:** two struct changes — `Element`/`Page` in
`obscura/src/page.rs` (raw pointer → `Weak<RefCell<InnerPage>>`) and `ObscuraElemName`
in `obscura-dom/src/tree_sink.rs` (raw pointer → `Ref<'a, QualName>`) — would eliminate
all 6 blocks that matter to your use case. Neither requires touching `obscura-browser`,
`obscura-js`, `obscura-net`, or any FFI/V8 boundary.

## Findings

### 1. CDP WebSocket has no Origin/Host validation
**Severity as originally scoped:** Critical. **Applicability: N/A (CDP-only).**
`crates/obscura-cdp/src/server.rs:960-984`. Not reachable — no `obscura-cdp` in your
dependency graph.

### 2. `--stealth` mode has zero SSRF validation on navigation
**Severity: Critical if applicable. Applicability: Applies if `stealth` feature enabled.**
`crates/obscura-browser/src/page.rs:274-282`, `crates/obscura-net/src/wreq_client.rs:76-155`.
The stealth navigation path uses a separate HTTP client (`wreq`) that skips the SSRF
guard (`validate_url`/`SsrfGuardResolver`) entirely. A page you're automating can set
`location.href="http://169.254.169.254/..."` (or any RFC1918/loopback address) and the
response comes back, with no `--allow-private-network`-equivalent opt-in required.
**Status: open — confirmed applicable.** You intend to enable `stealth`; fingerprinting
is a core, load-bearing part of this project going forward, so this needs to be fixed as
a first-class path, not left as an optional-feature gap.

### 3. Dynamic `import()` / `<script type=module>` bypasses SSRF protection
**Severity: Critical. Applicability: Applies.**
`crates/obscura-js/src/module_loader.rs:56-114`. This is in `obscura-js`, a dependency
of `obscura-browser`, so it's reachable regardless of CDP/MCP/stealth. The custom DNS
resolver that blocks private IPs (`SsrfGuardResolver`) is skipped by `hyper-util`
whenever the host is already a literal IP address (confirmed against the vendored
`hyper-util` source), and `module_loader.rs` never independently validates the URL
before fetching. A page you automate can do
`import('http://127.0.0.1:6379/').catch(()=>{})` or
`<script type="module" src="http://169.254.169.254/...">` and reach internal/loopback
services directly. **Status: open.**

### 4. JS-triggered navigation bypasses local-file-read protection entirely
**Severity: Critical. Applicability: Applies — and more relevant to your use case than
originally scoped.**
`crates/obscura-net/src/client.rs:273-285` (`validate_url`) lets `file://` through
unconditionally: `if scheme == "file" || allow_private_network { return Ok(()); }`.
The `allow_file_access` flag on `BrowserContext` (`crates/obscura-browser/src/context.rs:25`,
defaults `false`) is **never read anywhere in `obscura-browser` or `obscura-net`** — I
grepped every usage; it's only consulted inside `obscura-cdp`'s command handlers
(`domains/page.rs:239`, `domains/target.rs:67`), which you don't compile in. So in a
pure library-embedding setup, `allow_file_access` is dead code and provides **no
protection at all** against a page navigating (or being navigated) to a `file://` URL.
Concretely: a page you're automating with `<a href="file:///etc/passwd">` or a script
doing `location.href = "file:///etc/passwd"` causes `Page::process_pending_navigation()`
(`obscura-browser/src/page.rs:1701`) → `navigate_with_wait_post` → `fetch_with_method`
→ `validate_url` → local file read, and the file's bytes land in whatever your
automation reads next (page content, response body). There's a same-navigation-chain
redirect guard (`cross_scheme_to_file`, `page.rs:92-102`) but it only compares hops
*within* one navigation call — it does nothing for a fresh navigation that starts
directly at `file://`. **This is squarely inside your threat model** (untrusted sites,
deterministic automation) since it needs no CDP, no MCP, and no special access — just a
link or a redirect on a page you visit. **Confirmed relevant to your deployment** — your
automation does need to follow links/redirects on untrusted pages. **Status: open — top
priority.**

### 5. MCP HTTP server defaults to open CORS + no auth
**Severity as originally scoped:** High. **Applicability: N/A (MCP-only).**
`crates/obscura-mcp/src/http.rs`. Not reachable — no `obscura-mcp` in your dependency
graph.

### 6. `--stealth` `fetch()`/XHR SSRF check is literal-string only (no DNS resolution)
**Severity: High. Applicability: Applies — confirmed, same as #2.**
Same stealth code path as #2; vulnerable to DNS rebinding via a non-IP hostname that
resolves to a private address. **Status: open.**

### 7. Unbounded `crypto.subtle.deriveBits` iterations can hang script execution indefinitely
**Severity: Medium-High. Applicability: Applies (re-scoped from "wedges the whole CDP
server" to "hangs your automation's page evaluation").**
`op_subtle_pbkdf2` (`crates/obscura-js/src/ops.rs:1604-1623`) takes `iterations: u32`
uncapped from page JS (`crypto.subtle.deriveBits({..., iterations}, ...)`), and runs the
loop synchronously inside a native Rust op — not V8 bytecode. `SECURITY.md` and the
code comments both confirm `terminate_execution()` (what the V8 watchdog calls) only
takes effect when V8 resumes running *script*; it cannot preempt a Rust loop already
running inside an op. Your own timeouts (`tokio::time::timeout`, the
`OBSCURA_SCRIPT_DEADLINE_MS`/`OBSCURA_NAV_TIMEOUT_MS` deadlines in
`obscura-browser/src/page.rs`) are implemented the same way — they can't preempt a
non-yielding synchronous op either, only code that returns control to the async
executor at await points. A page doing
`crypto.subtle.deriveBits({name:'PBKDF2', hash:'SHA-256', salt, iterations: 4000000000}, key, 8)`
can hang your automation process for the full duration of ~4.3B HMAC iterations,
regardless of any deadline you configure. **Status: open.**

### 8. Cookie `Domain` matching has no public-suffix list
**Severity: Medium. Applicability: Applies.**
`crates/obscura-net/src/cookies.rs:555-572` (`resolve_cookie_domain`). A response from
`attacker.github.io` (or any multi-label public suffix not covered without a bundled
PSL — `herokuapp.com`, `vercel.app`, `co.uk`, etc.) can set a cookie scoped to
`Domain=github.io`, which then gets sent to every other tenant of that suffix your
automation visits. Relevant if your automation ever crosses shared-hosting domains and
carries cookies between them. **Status: open.**

### 9. Only 4 of 22 JS ops are panic-guarded; `SECURITY.md`'s "every op is panic-safe" claim doesn't hold
**Severity: Medium (latent). Applicability: Applies.**
`crates/obscura-js/src/ops.rs` — `catch_unwind` wraps `op_dom`, `op_url_parse`,
`op_url_set`, `op_url_resolve` only. No live panic was found reachable today (key/IV/
length validation is explicit elsewhere), but nothing structurally prevents a future op
— or a small change to one of the 18 unwrapped ones — from introducing a page-triggerable
panic that aborts the process instead of degrading gracefully, since `panic = "unwind"`
is what makes the wrapped ops safe and the unwrapped ones have no backstop. **Status:
open, no action needed today, worth a lint/test to prevent regression.**

### 10. Unbounded native heap allocation from JS-controlled length
**Severity: Medium. Applicability: Applies.**
`op_subtle_pbkdf2`/`op_subtle_hkdf` (`ops.rs:1606-1654`): `vec![0u8; length as usize]`
where `length` comes straight from `crypto.subtle.deriveBits(algorithm, key, length)`
with no cap (contrast `getRandomValues`, capped at 65536 bytes in `bootstrap.js`). Up to
~4 GiB can be requested per call, allocated outside V8's own heap ceiling; a failed
allocation at that size aborts the process via Rust's allocator-OOM path, which is not
catchable by any `catch_unwind`. **Status: open.**

### 11. Use-after-free / aliasing UB in the public `obscura::Element` API
**Severity: Medium-High. Applicability: Applies directly — this is the exact API
surface you're embedding. Same underlying bug as U1–U3 in the Unsafe Block Inventory
above — fixing U1–U3 (the `Weak<RefCell<InnerPage>>` design) resolves this finding
directly; see that section for the recommended fix and open verification item.**
`crates/obscura/src/page.rs:148-192`. `Element { node_id: u64, page: *const Page }` is
constructed with no lifetime tying it to the `Page` it points at
(`Element { node_id: nid, page: self as *const Page }`, lines 56/74), and `.text()`/
`.attribute()`/`.click()` all do `unsafe { &mut *(self.page as *mut Page) }` with no
`SAFETY` comment. Concretely:
```rust
let mut page = browser.new_page().await?;
let el = page.wait_for_selector("a", Duration::from_secs(5)).await?;
let page = page; // any move of `page` — into a Vec, returned from a function, etc.
el.text(); // dereferences a stale/moved-from address
```
Separately, and independent of any move: since `.text()` etc. cast to `&mut Page`
while the caller can simultaneously hold the original `&mut Page`/owned `Page`, you can
have two live mutable references to the same object, which is UB per Rust's aliasing
rules even without a use-after-free. **Status: open — worth fixing before you rely on
`Element` across any await point or control-flow that could move/drop the owning
`Page`.**

### 12. CDP page/session IDs are sequential, not random
**Severity as originally scoped:** Medium (compounds #1). **Applicability: N/A (CDP-only).**

### 13. Undocumented/fragile `unsafe` in `obscura-dom/src/tree_sink.rs`
**Severity: Low. Applicability: Applies (obscura-dom is a transitive dependency via
obscura-browser). Same underlying code as U4–U6 in the Unsafe Block Inventory above —
fixing U4–U6 (the `Ref::map`-based design) resolves this finding directly.**
Lines 18/25/29 hold a raw pointer into an arena `Vec` guarded by a `RefCell` borrow that
would panic (not silently corrupt) if violated. No confirmed exploit path found; no
`SAFETY` comments either. **Status: open, low priority.**

### 14. `SECURITY.md` claims a `cargo-deny`/`deny.toml` gate that doesn't exist
**Severity: Low.** Documentation/process gap, not a code vulnerability — flagged for
awareness since you're relying on this fork's stated posture. No `deny.toml` in the
repo; dependency versions themselves are current and clean (rustls 0.23, no
git-sourced deps).

### 15. Docker image runs as root by default
**Severity: Low. Applicability: N/A unless you use the published Docker image** (you're
embedding the library, not running the container).

## Open questions for you

1. ~~Do you (or will you) enable the `stealth` Cargo feature~~ — **confirmed: yes.**
   Fingerprinting/stealth is a core, load-bearing part of this project going forward, so
   findings #2 and #6 are treated as fully applicable, not conditional.
2. ~~Does your automation ever need to follow links/redirects on pages you don't fully
   trust~~ — **confirmed: yes.** Finding #4 is a real, not just theoretical, concern for
   this deployment.

Both open questions are now resolved. No fixes have been made in this repo yet — this
file is a record of what's been found. Actionable remediation work has been handed off
to NQAF (see below); this file remains as the background research/rationale behind
those prompts.

## Handoff to NQAF

This review's findings have been turned into NQAF ("not-quite-a-fork") prompts —
self-contained instructions for re-implementing each fix against a fresh mirror of
upstream, rather than a diff/patch — under `../prompts/` (relative to this file, i.e.
`nqaf/obscura/prompts/` in this repo). See that directory for the prompts covering
findings #3, #4 (feature-001/002), #2/#6 (feature-003), #11/#13/U1-U6 (feature-004),
#8 (feature-005), and #7/#9/#10 (feature-006). Findings #1, #5, #12, #14, #15 did not
get prompts: #1/#5/#12 are N/A to this project's embedding-only use case (CDP/MCP code
not compiled in), and #14/#15 are low-severity documentation/deployment notes rather
than code fixes worth an independent re-implementation prompt.
