# Fix: add an explicit, idempotent V8 platform init entry point

## Problem [feature-012]

Obscura never initializes the V8 platform explicitly. When a `Page` is
created, `obscura-browser`'s `Page` constructor builds the JS runtime
through `obscura-js`'s runtime module, which calls
`deno_core::JsRuntime::new`. deno_core 0.350 then initializes V8 lazily
inside `JsRuntime::new` (`deno_core`'s `runtime/setup.rs`, `init_v8`),
using the default **pkey-protected** platform, on whichever thread happens
to create the first runtime.

Upstream moves; locate code by name (`Page`, `JsRuntime::new`, `init_v8`,
`set_v8_flags`).

On x86-64 Linux CPUs with Intel PKU, V8 write-protects internal tables
such as `JSDispatchTable` with a memory protection key. Only the thread
that initialized the platform, and threads spawned from it afterwards, can
access those tables. A runtime created on any other thread (for example a
sibling thread off `main`) segfaults while the first isolate is still
alive:

```
v8::Isolate::New
  → Isolate::InitializeBuiltinJSDispatchTable
  → ExternalEntityTable<JSDispatchEntry, 268435456>::TryAllocateEntry
```

Obscura gives embedders no way to choose the initializing thread or the
platform. Initializing the default platform on `main` before spawning
threads fixes the crash, and so does using
`v8::new_unprotected_default_platform`.

One downstream embedder (c3) works around this today by calling
`deno_core::JsRuntime::init_platform(None, false)` in its `fn main()`.
That forces it to depend on deno_core directly and match obscura's
deno_core version by hand. It will switch to the API below and drop that
dependency, so the API must not require the caller to name any deno_core
or v8 type.

## Fix

### 1. `obscura_js::init_v8`

Add this public API to `obscura-js` (a new module, or next to
`crates/obscura-js/src/v8_flags.rs`):

```rust
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum V8Platform {
    /// V8's default platform (pkey-protected on PKU hardware). All JS
    /// runtimes must be created on the initializing thread, or on threads
    /// spawned from it after initialization. A runtime created on any
    /// other thread may segfault on x86-64 Linux with Intel PKU.
    #[default]
    Default,
    /// `v8::new_unprotected_default_platform`: no memory protection keys,
    /// so runtimes may be created on any thread. Use this when your thread
    /// layout is not under your control.
    Unprotected,
}

#[must_use]
pub fn init_v8(platform: V8Platform) -> V8Platform
```

Use the same name and signature at every layer (see step 2).

Mechanism:

- A private `static PLATFORM: OnceLock<V8Platform>`.
- A private `fn do_init(platform: V8Platform)` that does the real work:
  1. Apply obscura's configured V8 flags. Start from
     `crates/obscura-js/src/v8_flags.rs` and apply them here, before the
     platform is initialized.
  2. Call `deno_core::JsRuntime::init_platform`. For `Default`, pass
     `None`. For `Unprotected`, pass
     `Some(v8::new_unprotected_default_platform(...).make_shared())`
     (check that function's arguments in the locked `v8` version; thread
     pool size `0` means "V8 picks").
- Public `init_v8(p)`: `let kind = *PLATFORM.get_or_init(|| { do_init(p); p });`.
  If `kind != p`, log a warning (use the logging crate obscura already
  uses, e.g. `tracing`) that says V8 was already initialized with `kind`
  and `p` was ignored. Never panic. Return `kind`.
- Private `pub(crate) fn ensure_v8()`: only
  `PLATFORM.get_or_init(|| { do_init(V8Platform::Default); V8Platform::Default });`.
  It never compares and never warns.

So an embedder that calls `init_v8(Unprotected)` after obscura already
initialized `Default` implicitly gets a warning and a return value of
`Default`. That embedder is the one who can still segfault, so the warning
must fire in that case.

Details to check against the locked deno_core source, not against this
prompt:

- **The `init_platform` signature.** In 0.350 it is
  `init_platform(v8_platform: Option<SharedRef<Platform>>,
  import_assertions_enabled: bool)`. Call it with whatever signature the
  locked version actually has. Do not enable deno_core's
  `unsafe_use_unprotected_platform` Cargo feature; with it on, deno_core
  picks the unprotected platform itself and `init_platform` takes an extra
  argument.
- **The import-assertions value.** Obscura does not call `init_platform`
  today. `JsRuntime::try_new` calls `init_v8(options.v8_platform,
  cfg!(test), options.unsafe_expose_natives_and_gc(), import_assertions)`,
  deriving `import_assertions` from the `RuntimeOptions` that obscura
  builds. Pass the value that obscura's current `RuntimeOptions` produce,
  read from the locked deno_core source. c3's `false` is a hint, not the
  source of truth.
- **`expose_natives`.** The public `init_platform` hardcodes
  `expose_natives = false`. If obscura's `RuntimeOptions` turn on
  `unsafe_expose_natives_and_gc`, the new init would drop
  `--expose_gc --allow_natives_syntax`. Check that option. If it is on,
  say so in the commit message rather than dropping it silently.

**The return value's contract.** `init_v8` returns the kind that obscura's
first init requested. That is accurate only if nothing outside obscura
initialized V8 first: the `OnceLock` sees only inits that go through
obscura, and deno_core silently ignores a second platform init. Say this
in the rustdoc. Also say that embedders must remove any direct deno_core or
v8 platform init when they adopt `init_v8` (c3 must drop its
`init_platform(None, false)` call in the same change), and that calling it
from `main` before spawning threads is the intended use. The first call
wins; later calls are no-ops apart from the warning.

### 2. Re-export through `obscura-browser` and the facade

Follow the layering that the earlier DOM-telemetry prompt used for
`subscribe_dom_changes`:

- In `crates/obscura-browser/src/lib.rs`, next to the existing
  `pub use obscura_js::...` re-exports, add
  `pub use obscura_js::{init_v8, V8Platform};` (adjust the path to the
  module you chose).
- In `crates/obscura/src/lib.rs`, add
  `pub use obscura_browser::{init_v8, V8Platform};`, with a one-line doc
  pointer to the `obscura_js` rustdoc.

Embedders then call `obscura::init_v8` and name `obscura::V8Platform`,
with no other obscura crate and no deno_core or v8 dependency.

### 3. Route obscura's own runtime creation through `ensure_v8`

Find where obscura creates its `deno_core::JsRuntime` (in `obscura-js`'s
runtime module, reached from `obscura-browser`'s `Page` construction).
Call `ensure_v8()` immediately before `JsRuntime::new`. Because of the
`OnceLock`:

- Embedders who never call `init_v8` get today's behaviour: the default
  platform, initialized lazily on the thread that creates the first
  runtime. Single-thread and thread-descendant layouts keep working.
- An explicit earlier `init_v8` call wins, and `ensure_v8` becomes a no-op
  with no warning.

deno_core guards its own `init_v8` with a `Once`, so the call inside
`JsRuntime::new` stays harmless after obscura has initialized the
platform. Leave `RuntimeOptions.v8_platform` as `None` so that it cannot
override the platform chosen in step 1.

If other places in the fork create a `JsRuntime` (workers, the CDP server,
tests, benchmarks), route them through `ensure_v8` too. If the obscura
binary (CLI or CDP server) has its own `main` that spawns threads before
creating runtimes, call `init_v8(V8Platform::Default)` there, early.

Detecting at runtime that a thread lacks access to the protected platform
is out of scope: there is no reliable signal for it, and comparing thread
ids would reject valid layouts.

### 4. README

Add a subsection to the fork README under "About this fork" → "Fork
Features" (an earlier prompt in this series creates that section; create
it if it is missing). Show the call from `main`, using the return value:

```rust
fn main() {
    let platform = obscura::init_v8(obscura::V8Platform::Default);
    assert_eq!(platform, obscura::V8Platform::Default);
    // ... build the tokio runtime, spawn threads, create Browsers ...
}
```

Say when to choose `Unprotected` instead, and that any direct deno_core or
v8 platform init must be removed when adopting `init_v8`.

## Tests

The PKU crash itself cannot be reproduced on arm64 or on x86-64 hardware
without PKU, so do not try to test the crash. Do test the API.

V8 platform init is process-wide and happens once per process, and libtest
runs each `#[test]` on its own thread. Those threads are siblings. If two
tests in one binary share a `Default` init, every test but the first
creates its runtime on a sibling of the initializing thread, which is the
layout that crashes on PKU hardware while the first isolate is alive. So:

- **`Default`: one `#[test]` per integration-test file**, with the
  `init_v8` call and any child threads inside that test. In that one test:
  call `init_v8(Default)` twice and check that both return `Default`; call
  `init_v8(Unprotected)` and check that it returns `Default` without
  panicking; then create a `Browser`/`Page` and evaluate a trivial script.
  Optionally, also spawn a thread from inside the test after init and
  evaluate a script on a `Page` created there.
- **`Unprotected`: a separate integration-test file.** Several tests may
  share one binary here, since the unprotected platform has no thread
  restriction. Every test in that file must call `init_v8(Unprotected)`
  before anything else, so that no `Page` triggers the implicit `Default`
  init first. Check that `init_v8(Unprotected)` returns `Unprotected`
  (also on a second call), that a later `init_v8(Default)` returns
  `Unprotected`, and that a `Page` created on a separate thread evaluates a
  script.

Run `cargo test` and `cargo clippy` for the touched crates and fix what
they report.

## Why this matters

Embedders that create obscura runtimes on more than one thread can then
run on x86-64 Linux with Intel PKU through obscura's own API, without
reaching into deno_core.
