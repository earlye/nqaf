# Fix: add an explicit, idempotent V8 platform init entry point

## Problem [feature-012]

Obscura never initializes the V8 platform explicitly. When a `Page` is
created, the browser crate (`obscura-browser`, the `Page` constructor in
its `page.rs`) builds the JS runtime through `obscura-js` (its `runtime.rs`,
where it calls `deno_core::JsRuntime::new`). deno_core 0.350 then
initializes V8 lazily inside `JsRuntime::new` (`deno_core`'s
`runtime/setup.rs`, `init_v8`), using the default **pkey-protected**
platform, on whichever thread happens to create the first runtime.

Line numbers in this prompt are approximate and upstream moves; locate code
by the names given here (`Page`, `JsRuntime::new`, `init_v8`,
`set_v8_flags`), not by line.

On x86-64 Linux CPUs with Intel PKU (the `pku`/`ospke` CPU flags; for
example the Amazon Linux 2023 EC2 instances that a downstream user runs
on), V8 write-protects internal tables such as `JSDispatchTable` with a
memory protection key. Only the thread that initialized the platform, and
threads spawned from it afterwards, can access those tables. A runtime
created on any other thread segfaults while the first isolate is still
alive:

```
v8::Isolate::New
  → Isolate::InitializeBuiltinJSDispatchTable
  → ExternalEntityTable<JSDispatchEntry, 268435456>::TryAllocateEntry
```

The kernel logs `segfault ... error 25`; 0x25 includes the PK-violation
bit. arm64 (Apple Silicon, Graviton) has no PKU, so the crash never shows
there. deno_core's own docs say that every runtime must run on a thread
descended from the one that initialized the platform, but obscura gives
embedders no way to choose that thread.

How it shows up downstream: an embedder (c3) spawns a new std thread per
browser command, all of them siblings off `main`. The first command
initializes V8 on its own thread; the second command's thread segfaults
every time. A standalone 30-line repro against `v8` 137.3.0 shows the same
fault, and either of these fixes it:

- initializing the default platform on `main` before spawning threads;
- using `v8::new_unprotected_default_platform` instead of the default.

c3 currently works around this by calling
`deno_core::JsRuntime::init_platform(None, false)` in its synchronous
`fn main()` before building its tokio runtime. That forces c3 to depend on
deno_core directly, and to match obscura's deno_core version by hand. Once
this fork exposes an init API, c3 will switch to it and drop that
dependency. So the new API must not require the caller to name any
deno_core or v8 type.

## Fix

### 1. An idempotent init entry point in `obscura-js`

Add a public function in `obscura-js` (e.g. `obscura_js::init_platform`)
that wraps `deno_core::JsRuntime::init_platform`. Check the real signature
of `JsRuntime::init_platform` in the deno_core version that this fork
locks; at the time of writing it takes an optional
`v8::SharedRef<v8::Platform>` and a bool, and c3 calls it as
`(None, false)`. Pass whatever obscura's own runtime creation passes today
for the second argument, so behaviour does not change.

Requirements:

- **Safe to call more than once.** Guard it with `std::sync::OnceLock` (or
  `Once` plus a stored value). The first call does the work; every later
  call is a no-op.
- **Platform choice.** Take an argument that selects the platform without
  exposing deno_core or v8 types, e.g.

  ```rust
  #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
  pub enum V8Platform {
      /// V8's default platform (pkey-protected on PKU hardware). All JS
      /// runtimes must be created on the initializing thread or on threads
      /// spawned from it after this call.
      #[default]
      Default,
      /// `v8::new_unprotected_default_platform`: no memory protection keys,
      /// so runtimes may be created on any thread. Use this when your
      /// thread layout is not under your control.
      Unprotected,
  }

  pub fn init_platform(platform: V8Platform) -> V8Platform
  ```

  An options struct is fine too if it fits the crate better. For
  `Unprotected`, build the platform with
  `v8::new_unprotected_default_platform(...)` (check its arguments in the
  locked `v8` version; thread pool size `0` means "V8 picks") and
  `.make_shared()`, and pass it as `Some(...)`. For `Default`, pass `None`
  and let deno_core build its default, as today.
- **Return the platform that is actually in effect.** If the platform was
  already initialized, return the kind chosen by the first call. If a later
  call asked for a different kind, also log a warning (use whatever logging
  crate obscura already uses, e.g. `tracing`) and do **not** panic.
- **Apply V8 flags first.** Find how obscura sets V8 flags today (search for
  `set_v8_flags`, `v8_set_flags`, `V8::set_flags_from_string` and the
  places that build `RuntimeOptions`). Any flags that obscura or the
  embedder has configured must be applied before the platform is
  initialized, on both the explicit and the implicit path (see step 3). If
  flags can be configured after init (for example through a setter that the
  embedder may call late), document that flags set after the first init
  have no effect, and log a warning in that case if it is cheap to detect.
- **Rustdoc** on the function and on the enum. State plainly: call this
  from `main` (or the thread that will own all JS work) before spawning any
  thread that creates a `Browser`/`Page`; with `Default`, every runtime
  must be created on the initializing thread or on a thread spawned from it
  afterwards, or it may segfault on x86-64 Linux with Intel PKU; use
  `Unprotected` if that cannot be guaranteed. Mention that the first call
  wins and later calls are no-ops.

### 2. Re-export it from the public facade

Embedders depend on the public facade crate, not on `obscura-js` directly.
Find that crate (in this fork it is the plain `obscura` crate under
`crates/obscura/`, the one that wraps `obscura-browser`'s `Page` in its own
`Page`; confirm this by checking which crate exposes `Browser`/`Page` to
embedders). Expose the entry point there under a short name, e.g.
`obscura::init_v8(platform)`, and re-export the platform enum (e.g.
`obscura::V8Platform`), so an embedder needs no other obscura crate and no
deno_core or v8 dependency to call it. If the facade does not already
depend on `obscura-js`, add the dependency or route the call through
`obscura-browser`, whichever matches the existing crate layering.

### 3. Route obscura's own runtime creation through the same init

Find where obscura creates its `deno_core::JsRuntime` (in `obscura-js`'s
runtime module, reached from `obscura-browser`'s `Page` construction).
Immediately before `JsRuntime::new`, call the step-1 function with
`V8Platform::Default`. Because of the `OnceLock`:

- Embedders who never call the new API get exactly today's behaviour: the
  default platform, initialized lazily on the thread that creates the first
  runtime. Single-thread and thread-descendant layouts keep working.
- An explicit earlier call wins; the implicit call becomes a no-op and must
  **not** log the "different kind requested" warning from step 1. Give the
  implicit path a way to say "default unless already initialized" (for
  example a private helper, or an internal flag) so the warning is reserved
  for two explicit calls that disagree.

deno_core also guards its own `init_v8` with a `Once`, so the call inside
`JsRuntime::new` stays harmless after obscura has already initialized the
platform. Make sure `RuntimeOptions.v8_platform` is left `None` (or
otherwise cannot override the platform chosen in step 1).

If there are other places in the fork that create a `JsRuntime` (workers,
the CDP server, tests, benchmarks), route them through the same call.

### 4. Docs

- Rustdoc as described in step 1, plus a one-line pointer on the facade
  re-export.
- Add a subsection to the fork README under "About this fork" → "Fork
  Features" (an earlier prompt in this series creates that section; create
  it if it is missing). Describe the threading requirement, show the
  `main`-first call:

  ```rust
  fn main() {
      obscura::init_v8(obscura::V8Platform::Default);
      // ... build the tokio runtime, spawn threads, create Browsers ...
  }
  ```

  and say when to choose `Unprotected` instead.
- If the obscura binary (CLI or CDP server) has its own `main` that spawns
  threads before creating runtimes, call `init_v8` there too, early.

### 5. Optional: fail loudly instead of segfaulting

Only do this if it can be done reliably; it is not required. The goal
would be a clear panic or error, rather than a segfault, when a runtime is
created on a thread that cannot access the protected platform. The hard
part is that "descended from the initializing thread" is not something
Rust can check: a thread spawned from the initializing thread after init is
fine, and a sibling is not, but both are simply "a different thread". A
check that only compares thread ids would reject valid layouts, so do not
turn such a check into a panic or error. If you can find a reliable signal
(for example, an API in the locked `v8`/deno_core versions that reports
whether the current thread has pkey access), use it. Otherwise skip this
step and say so in the commit message.

## Tests

The PKU crash itself cannot be reproduced on arm64 or on x86-64 hardware
without PKU, so do not try to test the crash. Do test the API:

- Calling the init function twice (same kind) is fine, and the second call
  returns the kind from the first.
- Calling it with a different kind after init returns the first kind and
  does not panic.
- After an explicit init, creating a `Browser`/`Page` and evaluating a
  trivial script works.
- If feasible: init on the test thread, then spawn a new thread *after*
  init and create a runtime (or `Page`) on it and evaluate a script.

V8 platform init is process-wide and happens once, and `cargo test` runs
the tests in one binary on separate threads in the same process. A test
that needs to control which thread initializes first, or which kind is
chosen first, must live in its own integration-test file (its own binary),
with a single `#[test]` in it or with the init done once in a shared
helper. Put the `Unprotected` test in a separate file from the `Default`
ones for the same reason.

Run `cargo test` and `cargo clippy` for the touched crates and fix what
they report.

## Why this matters

Embedders that create obscura runtimes on more than one thread cannot run
on x86-64 Linux with Intel PKU today unless they reach past obscura into
deno_core, which ties them to obscura's exact deno_core version. An
explicit, idempotent init in the facade lets them pick the initializing
thread (or opt out of pkey protection) through obscura's own API, while
embedders that do nothing keep the current behaviour.
