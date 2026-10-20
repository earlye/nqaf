# obscura: explicit V8 platform init, to avoid PKU segfaults on sibling threads

## Context

Reported from the c3 session (branch `cf3d879e4a91-run-c3-on-remote-amazon-linux`) on the user's behalf.

obscura never initializes the V8 platform explicitly. `Page` (`obscura-browser/src/page.rs:300` → `obscura-js/src/runtime.rs:121`, `JsRuntime::new`) leaves it to deno_core 0.350, which initializes V8 lazily, with the default pkey-protected platform, on whichever thread creates the first runtime (`deno_core/runtime/setup.rs:83`).

On x86-64 Linux CPUs with Intel PKU (`pku`/`ospke` flags, e.g. the AL2023 EC2 box), V8 write-protects internal tables such as `JSDispatchTable` with a memory protection key. Only the initializing thread, and threads spawned from it afterwards, can access them. A runtime created on any other thread segfaults:

```
v8::Isolate::New
  → Isolate::InitializeBuiltinJSDispatchTable
  → ExternalEntityTable<JSDispatchEntry, 268435456>::TryAllocateEntry
```

The kernel logs `segfault ... error 25`; 0x25 includes the PK-violation bit. arm64 (Apple Silicon, Graviton) has no PKU, so the crash never shows there. deno_core's own docs say every runtime must run on threads descended from the one that initialized the platform.

## Reproduction

- **In c3:** the agent spawns a new std thread per browser command, all siblings off main. The first browser command initializes V8 on its thread, and the second command's thread segfaults every time.
- **The initializing thread's isolate must still be alive.** In the standalone repro, keeping the first isolate alive while a sibling thread creates a second exits 139 (segfault); dropping the first before the sibling creates its own exits 0. Obscura embedders that hold a long-lived browser session always meet this condition. (Corrected 2026-10-20; the first report said dropping the first isolate still crashed.)
- **Standalone:** a 30-line repro against `v8` 137.3.0 creates an isolate on a sibling thread and exits 139 with the same fault signature. Either of these fixes it:
  - initializing the default platform on main first;
  - using `v8::new_unprotected_default_platform`.

## What the fork needs

- **An explicit init entry point** that is safe to call more than once, e.g. `obscura::init_v8()` / `obscura_js::init_platform(...)`, wrapping `deno_core::JsRuntime::init_platform`. Embedders call it from their main thread before spawning threads. It must apply any `set_v8_flags` before initializing.
- **Docs** stating the threading requirement.
- **Optional:** a way to choose the unprotected platform, for embedders with arbitrary thread layouts.
- **Optional:** a guard that fails loudly instead of segfaulting when a runtime is created on a thread without platform access.

This would be a new `obscura/prompts/feature-NNN.md` carried by nqaf.

## Downstream

c3 ships a workaround meanwhile: it calls `deno_core::JsRuntime::init_platform(None, false)` in the agent's synchronous `fn main()` before building the tokio runtime (https://github.com/cerby-engineering/c3/pull/133). Once the fork exposes an init API, c3 should switch to it and drop its direct deno_core dependency.

## Relevant files

- `obscura-browser/src/page.rs:300`: `Page` creates the JS runtime
- `obscura-js/src/runtime.rs:121`: `JsRuntime::new`, where V8 gets initialized lazily
- `deno_core/runtime/setup.rs:83` (deno_core 0.350): lazy platform init
