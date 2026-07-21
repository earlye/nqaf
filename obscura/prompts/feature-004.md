# Fix: remove unsound raw-pointer `unsafe` blocks in `Element` and `ObscuraElemName`

## Problem [feature-004]

Two structs in this codebase hold raw pointers with no lifetime or ownership
tie to what they point at, and dereference them via `unsafe` with no `SAFETY`
justification:

**1. `obscura::Element`** (in the public embedding crate, `obscura`'s page
module). It's defined roughly as:

```rust
pub struct Element {
    node_id: u64,
    page: *const Page,
}
```

created as `Element { node_id: nid, page: self as *const Page }` from a
`&mut Page`, with no lifetime tying the pointer to the `Page` it came from.
Every accessor (`text()`, `attribute()`, `click()`) does
`unsafe { &mut *(self.page as *mut Page) }` to get mutable access back to the
`Page` so it can call `evaluate()`. Concretely, this means:

- If the originating `Page` is moved (returned from a function, pushed into a
  `Vec`, etc.) or dropped, any `Element` created from it holds a dangling
  pointer, and calling any of its methods is a use-after-free / dereference of
  an invalid address.
- Independent of any move: since these methods cast to `&mut Page` while the
  caller can simultaneously hold the original `Page` (owned or `&mut`), it's
  possible to have two live mutable references to the same object at once,
  which is undefined behavior under Rust's aliasing rules even without an
  actual use-after-free.

**2. `obscura-dom`'s `ObscuraElemName`** (in the `tree_sink` module, implementing
html5ever's `TreeSink::ElemName` for the DOM arena). It holds a raw
`*const QualName` pointer into the arena, obtained by borrowing the arena via
`RefCell::borrow()` and then discarding the actual `Ref` guard in favor of a
type-erased `Ref<'a, ()>` (via `Ref::map(borrow, |_| &())`) that exists only to
keep the `RefCell`'s runtime borrow-count incremented. This means a concurrent
mutating borrow of the arena elsewhere would panic rather than alias — but
nothing statically ties the raw pointer's validity to that guard, and all
three of its accessor methods dereference it via bare `unsafe` with no
`SAFETY` comment.

## Fix

**For `Element`:** restructure it to hold a `Weak` reference instead of a raw
pointer, rather than either of the two alternatives below (both were
considered and rejected for this codebase — see rationale):

- *Rejected: lifetime-bound borrow* (`Element<'a> { page: &'a mut Page }`,
  `text`/`attribute`/`click` taking `&mut self`). This removes the unsafe
  block but forces every caller to drop all `Element`s derived from a `Page`
  before calling any other method on that `Page` (e.g. `goto()`) — a real
  ergonomic cost, enforced by the borrow checker rather than something callers
  can work around.
- *Rejected: generational handle* (`Element { node_id, epoch: u64 }`, `Page`
  tracking a bumped `epoch`, checked on each access). This removes the
  lifetime constraint, but a per-`Page` epoch that starts fresh isn't unique
  across different `Page` instances — two different `Page`s can land on the
  same epoch value, and an `Element` from one could be (incorrectly) accepted
  by the other. Avoiding that needs either a composite `(page_id, epoch)` key
  or a single globally-issued counter shared across all pages and all
  navigations — more moving parts than the `Weak` approach below for the same
  guarantee.
- **Use instead:** change `Page`'s internal state to be held behind
  `Rc<RefCell<InnerPage>>` (verify first whether `Rc` or `Arc` is
  appropriate — see verification note below), and give `Element` a
  `page: Weak<RefCell<InnerPage>>` (via `Rc::downgrade`). Accessor methods
  become: `self.page.upgrade().ok_or(Error::PageDropped)?`, then
  `.borrow_mut()` to get mutable access, then call the underlying `evaluate`
  or equivalent. This removes the `unsafe` block entirely — `Weak::upgrade()`
  returns `None` once the `Page` is dropped instead of ever dereferencing a
  stale address, and because a `Weak` is tied to one specific `Rc` allocation
  rather than a numeric id, an `Element` from one `Page` can never be confused
  with or accepted by a different `Page` — there's no id to collide, so the
  generational-handle collision problem doesn't apply here. It also survives
  the `Page` wrapper being moved (not just kept alive), since the `Rc`/`Weak`
  point at the heap allocation, not at wherever the `Page` struct itself
  happens to live on the stack.
- **Verification note:** before implementing, confirm whether `Page`/the
  underlying JS runtime handle needs to remain `Send` (e.g. if any embedder
  moves a `Page` into a spawned task on a multi-threaded async runtime). A
  quick compile-time check (a scratch test asserting `Page: Send`) will settle
  this. If `Page` is already not `Send` today (likely, if it wraps a V8
  isolate handle, since V8 isolates must stay pinned to their creating
  thread), use plain `Rc`/`RefCell` — no loss of capability. If it somehow is
  `Send` today, use `Arc<tokio::sync::Mutex<InnerPage>>` instead to avoid a
  regression, and be careful not to hold the lock across an `.await` point if
  any of `Page`'s methods are `async`.
- This change should be containable to the crate that defines the public
  `Element`/`Page` wrapper types; the crate underneath that implements the
  actual browser/page logic should not need to change.

**For `ObscuraElemName`:** keep the `Ref` mapped all the way down to the field
instead of erasing it to `Ref<'a, ()>`. Concretely, change the construction so
it produces a `Ref<'a, QualName>` directly (via `Ref::map` on the arena borrow,
matching against the node and its data variant, panicking on the same
invalid-node/non-element cases the current code already panics on), store that
as the struct's only field, and implement the trait methods and `Debug` via
ordinary field access/`Deref` (`&self.name`, `&self.name.ns`, `&self.name.local`)
instead of raw-pointer dereferences. `Ref::map` exists precisely for "borrow a
sub-field of something behind a `RefCell` and keep the runtime borrow-check
alive for as long as you hold the sub-borrow" — this is a straightforward,
fully safe use of it, and removes all three `unsafe` blocks in this file in one
change.

## Why this matters

Both are real memory-safety bugs (a dangling-pointer dereference and a
mutable-aliasing violation) reachable from the project's own public embedding
API — not from untrusted page content, but from ordinary use of the library by
its host application (e.g. querying an element, then moving or continuing to
use the `Page` it came from). Fixing them removes real `unsafe` code with no
loss of functionality and no measurable performance cost.
