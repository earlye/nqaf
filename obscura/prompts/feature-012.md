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

Add this public API in a new module, `crates/obscura-js/src/platform.rs`,
and re-export it at the crate root as `obscura_js::{init_v8, V8Platform}`:

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

pub fn init_v8(platform: V8Platform) -> V8Platform
```

Mechanism:

- A private `static PLATFORM: OnceLock<(V8Platform, bool)>`, holding the
  kind that was initialized and whether that first init was explicit (a
  call to `init_v8`) or implicit (`ensure_v8`, below).
- A private `fn do_init(platform: V8Platform)` that does the real work:
  1. Call `crate::v8_flags::mark_platform_started()`. Confirm the
     following in `crates/obscura-js/src/v8_flags.rs`; it is expected, not
     verified against the fork. That module is expected to keep no stored
     flag configuration. Its public `set_v8_flags(&str)` is expected to
     apply flags immediately through `v8::V8::set_flags_from_string`. Its
     only protection against a late call is expected to be a
     `PLATFORM_STARTED` flag, which `mark_platform_started()` sets and
     which runtime construction currently sets. Setting flags after
     platform init makes V8 call `V8_Fatal` and abort the process. So
     `do_init` must mark the platform as started before `init_platform`,
     or a `set_v8_flags` call after an explicit `init_v8` would abort.
     Keep `set_v8_flags` as an immediate apply (the CLI and tests use it),
     do not buffer flags, and keep the existing `mark_platform_started()`
     call in runtime construction. If the module differs from this
     description, keep the same goal: any flag call after `init_v8` must
     be rejected the way a late call is rejected today, not abort.
  2. Call `deno_core::JsRuntime::init_platform`. For `Default`, pass
     `None`. For `Unprotected`, pass
     `Some(v8::new_unprotected_default_platform(...).make_shared())`
     (check that function's arguments in the locked `v8` version; thread
     pool size `0` means "V8 picks").
- Public `init_v8(p)`:
  `let (kind, explicit) = *PLATFORM.get_or_init(|| { do_init(p); (p, true) });`.
  Log with `tracing::warn!` in either of these cases, and never panic:
  - `kind != p`: V8 was already initialized with `kind`, and `p` was
    ignored.
  - `!explicit`: V8 was already initialized implicitly by runtime
    creation, so this call cannot choose the initializing thread. This
    fires even when `kind == p`: a `Page` created on another thread before
    `main` calls `init_v8(Default)` is exactly the layout that crashes on
    PKU hardware.

  Return `kind`.
- Crate-private `pub(crate) fn ensure_v8()` (see step 3 for the one case
  where it must be `#[doc(hidden)] pub` instead): only
  `PLATFORM.get_or_init(|| { do_init(V8Platform::Default); (V8Platform::Default, false) });`.
  It never compares and never warns.

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
from `main` before spawning threads is the intended use, and that any
`set_v8_flags` call must come before `init_v8`. The first
initialization wins, whether it came from an `init_v8` call or from
obscura creating its first runtime. Later calls change nothing; they log a
warning if their requested kind was ignored or if V8 was already
initialized implicitly.

### 2. Re-export through `obscura-browser` and the facade

Follow the layering already used for `subscribe_dom_changes`:

- In `crates/obscura-browser/src/lib.rs`, next to the existing
  `pub use obscura_js::...` re-exports, add
  `pub use obscura_js::{init_v8, V8Platform};`.
- In `crates/obscura/src/lib.rs`, add
  `pub use obscura_browser::{init_v8, V8Platform};`, with a one-line doc
  pointer to the `obscura_js` rustdoc.

### 3. Route obscura's own runtime creation through `ensure_v8`

`ObscuraJsRuntime::new` in `crates/obscura-js/src/runtime.rs` is expected
to be the only `JsRuntime::new` call in the fork (every `Page` builds its
runtime through it); confirm this with a search. Call `ensure_v8()`
immediately before that `JsRuntime::new`. Embedders who never call
`init_v8` then get today's behaviour: the default platform, initialized
lazily on the thread that creates the first runtime. Single-thread and
thread-descendant layouts keep working.

deno_core guards its own `init_v8` with a `Once`, so the call inside
`JsRuntime::new` stays harmless after obscura has initialized the
platform. Leave `RuntimeOptions.v8_platform` as `None` so that it cannot
override the platform chosen in step 1.

If you find a `JsRuntime::new` outside `obscura-js`, make `ensure_v8`
`#[doc(hidden)] pub` (do not re-export it from `obscura-browser` or the
facade) and call it there. Never call `init_v8` once per runtime: that
call is explicit, so it would either hide the warning for a later
`init_v8` from `main` (if it ran first on a worker thread) or log a
warning for every runtime (if a `Page` had already initialized V8
implicitly).

The CDP server is expected to initialize V8 early with
`drop(ObscuraJsRuntime::new())`; confirm this, and leave it as it is
(it goes through `ensure_v8`). If the obscura binary (CLI or CDP server)
has a `main` that spawns threads before creating runtimes and does not
already initialize V8 early, call `init_v8(V8Platform::Default)` there,
early, but after its existing `set_v8_flags` call.

Detecting at runtime that a thread lacks access to the protected platform
is out of scope: there is no reliable signal for it, and comparing thread
ids would reject valid layouts.

### 4. README

Add a subsection to the fork README under "About this fork" → "Fork
Features" (feature-011 creates that section; create it if it is
missing). Show the call from `main`:

```rust
fn main() {
    obscura::init_v8(obscura::V8Platform::Default);
    // ... build the tokio runtime, spawn threads, create Browsers ...
}
```

Add one sentence on the return value: for callers that call `init_v8`
later, it reports the kind that obscura's first init requested, which may
differ from the one they asked for. Say when to choose `Unprotected`
instead, and that any direct deno_core or v8 platform init must be removed
when adopting `init_v8`. Also say that any `set_v8_flags` call must come
before `init_v8`.

## Tests

The PKU crash itself cannot be reproduced on arm64 or on x86-64 hardware
without PKU, so do not try to test the crash. Do test the API.

V8 platform init happens once per process, and each integration-test
file is its own process. libtest runs each `#[test]` on its own thread,
and those threads are siblings. Two tests in one binary would therefore
share one init: the second test could not choose the platform or the
initializing thread, and with `Default`, it would create its runtime on a
sibling of the initializing thread, which is the layout that crashes on
PKU hardware while the first isolate is alive. Test order is not fixed
either, so which test initializes first would vary between runs.

So write three integration-test files, each containing exactly one
`#[test]`, with every init and any child threads inside that test:

- **Implicit `Default` (the warning path).** First create a
  `Browser`/`Page` without calling `init_v8` and evaluate a trivial
  script; this is the implicit init. Then call `init_v8(Default)` twice and
  check that both calls return `Default` without panicking (they take the
  "initialized implicitly" warning path). Then call `init_v8(Unprotected)`
  and check that it returns `Default` without panicking.
- **Explicit `Default` (the path that c3 and the README use).** Call
  `init_v8(Default)` and check that it returns `Default`. Create a `Page`
  and evaluate a script. Then spawn a thread inside the test, create a
  `Page` there and evaluate a script. Optionally, also call
  `set_v8_flags` after `init_v8` and check that the process does not
  abort and that the call is rejected the way a late call is rejected
  today.
- **`Unprotected`.** Call `init_v8(Unprotected)` twice and check that both
  calls return `Unprotected`. Check that a later `init_v8(Default)` returns
  `Unprotected`. Then spawn a thread, create a `Page` on it and evaluate a
  script.

Run `cargo test` and `cargo clippy` for the touched crates and fix what
they report.

## Why this matters

Embedders that create obscura runtimes on more than one thread can then
run on x86-64 Linux with Intel PKU through obscura's own API, without
reaching into deno_core.
