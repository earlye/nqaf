# Fix: unbounded WebCrypto derive-bits parameters, and inconsistent op panic-guarding

## Problem [feature-006]

Three related gaps in `obscura-js`'s native op layer (the Rust functions that
back JS-visible APIs like `crypto.subtle`):

**1. Unbounded iteration count → unkillable hang.** The PBKDF2 op
(`crypto.subtle.deriveBits({name:'PBKDF2', ...iterations})`) takes the
caller-supplied `iterations` as a `u32` with no upper bound, and runs that many
HMAC iterations synchronously inside the native op — not as V8 bytecode. This
project's execution watchdog (whatever mechanism terminates a runaway script,
e.g. `terminate_execution`-style V8 termination) only takes effect when V8
resumes running script; it cannot interrupt a Rust loop already running inside
a synchronous op. A page calling
`crypto.subtle.deriveBits({name:'PBKDF2', hash:'SHA-256', salt, iterations: 4000000000}, key, 8)`
can hang script execution for as long as ~4 billion HMAC iterations take,
regardless of any timeout/deadline the embedder has configured — those
deadlines are implemented the same way (they can't preempt a non-yielding
synchronous op either).

**2. Unbounded output length → uncatchable OOM abort.** The same op (and the
HKDF equivalent) allocates its output buffer directly from the caller-supplied
`length` parameter with no cap — up to ~4 GiB can be requested per call. This
allocation happens on Rust's own heap, entirely outside whatever heap ceiling
the JS engine itself enforces (e.g. V8's `--max-old-space-size`). A failed
allocation at that size aborts the process via the Rust allocator's
out-of-memory path, which is not something a panic handler can catch.

**3. Inconsistent panic-guarding across ops.** Only a handful of the
registered ops (something like 4 out of ~20+) are wrapped in
`std::panic::catch_unwind` so that a panic degrades to a null/error result
instead of aborting the process. The rest have no such wrapper. No live panic
is currently reachable through the unwrapped ops (this was checked — key/IV/
length validation is done via explicit `match`/`if` returning `Err` rather than
`.unwrap()`), but nothing structurally prevents a future op, or a small edit to
an existing unwrapped one, from introducing a page-triggerable panic that
aborts the whole process instead of degrading gracefully.

## Fix

1. Cap `iterations` for PBKDF2 (and any other iterative KDF/hash op with a
   caller-supplied iteration count) to a fixed, generous-but-bounded maximum
   (pick something well above any legitimate use — e.g. in the low millions —
   and make it easy to find/adjust as a named constant). Reject anything above
   the cap with a normal `Err`/JS exception rather than silently clamping it,
   so callers get a clear signal rather than a surprising truncation.
2. Cap the output `length` parameter the same way (a named constant, rejected
   with an error above the cap), consistent with how `crypto.getRandomValues`
   in this codebase already caps its own length parameter — use the same style
   of bound for consistency.
3. Establish a single, enforced wrapping mechanism for every registered op
   (not just the ones that happen to need it today), so a panic anywhere in
   the op layer degrades to an error result instead of aborting. Prefer a
   pattern that's structurally hard to skip — e.g. a single registration
   helper that all ops go through and that applies the `catch_unwind` wrapper
   uniformly, rather than requiring each op author to remember to add it
   individually. Add a test (or a build-time/lint-time check, if practical)
   that would catch a newly-added op that bypasses the wrapper.
4. Add regression tests: PBKDF2/HKDF calls above the iteration/length caps are
   rejected quickly (not run to completion first); calls at or below the caps
   still succeed; and a deliberately panicking op (introduced only in the test)
   degrades to an error rather than crashing the test process.

## Why this matters

(1) and (2) are both page-triggerable denial-of-service primitives that this
project's existing timeout/watchdog machinery cannot stop, since they hang or
abort inside native code rather than JS bytecode — exactly the class of bug
this project's own documented threat model calls out as in-scope
("availability... a page that defeats the termination watchdog... and so
hangs or aborts the process"). (3) is not an active bug today but removes the
safety margin that would otherwise catch a future regression before it
reaches production.
