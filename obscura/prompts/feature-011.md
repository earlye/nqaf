# Fix: expose `obscura-browser::Page::id` through the public `obscura` facade

## Problem [feature-011]

You are an expert Rust systems engineer modifying our codebase fork of
Obscura. Our goal is to expose a thread-safe, high-performance DOM
change event stream that an external Rust automation engine housing
this fork can consume seamlessly.

Because Obscura's V8 engine loop (`deno_core` ops) runs on a `!Send`
thread-local architecture, we cannot safely pass closures or direct
cross-thread pointers into the ops layer. Instead, implement a
lock-free, global unbounded telemetry channel using
`crossbeam-channel` or `tokio::sync::mpsc`.

Please implement the following changes precisely, keeping in mind
Obscura's performance-first architecture:

1. Create a `telemetry` module (or modify `obscura-js/src/ops.rs`
   directly) to define a thread-safe `TelemetryDomEvent` enum. Include
   variants for node insertions, node removals, and attribute changes,
   passing only lightweight types (like atomic node IDs as `u32` or
   static identifiers) to avoid cloning massive strings inside the V8
   execution path.

2. Initialize a global lazy static channel (`once_cell::sync::Lazy`)
   that exposes a `Sender<TelemetryDomEvent>` and a
   `Receiver<TelemetryDomEvent>`.

3. Provide a public function `pub fn subscribe_dom_changes() ->
   crossbeam_channel::Receiver<TelemetryDomEvent>` (or an async
   equivalent if tokio is preferred) that our containing automation
   engine can pull from.

4. Locate the central Deno/V8 bindings within `obscura-js/src/ops.rs`
   (such as `#[op] fn op_dom_insert_before` or related structural
   mutation ops). Wrap these operations so that every time a DOM
   change executes, a fire-and-forget payload is dispatched
   immediately out of the thread-local environment to our telemetry
   queue.

5. Provide a usage example showing how our companion Rust automation
   framework can run a background thread loop to monitor these
   streaming `TelemetryDomEvent` items without deadlocking Obscura's
   engine or dropping frames.

Ensure all additions conform to Obscura's existing crate layout, avoid
introducing blocking locks inside `#[op]` macros, and pass `cargo
clippy` guidelines.
