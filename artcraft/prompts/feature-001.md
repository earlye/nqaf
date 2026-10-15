# Remove the startup login gate

## Problem [feature-001]

On launch, ArtCraft forces a sign-up/login modal that cannot be dismissed.
The project is MIT/Apache licensed, and much of the app (local canvas, 3D
scene, video editor, moodboard, and generation through bring-your-own-key
providers such as Fal) does not need an ArtCraft account. A user should be
able to use the app without signing up.

As of this writing the gate lives in the login modal component
(`frontend/libs/components/login-modal/src/lib/login-modal.tsx`):

- A `useEffect` keyed on the store's `recheckTrigger` calls
  `getNativeLoginSession()` and, when there is no session (null or error),
  calls `useLoginModalStore.getState().openModal()`.
- The modal has no dismiss control (the backdrop has no click handler, and a
  comment says "no dismiss control — login is required").

`MainApp.tsx` mounts `<LoginModal>` unconditionally. Routing is not a gate:
`withProtectedRoute` already renders unconditionally.

## Fix

- Do not auto-open the login modal when the startup session check finds no
  session. The session check itself should still run, so an existing
  session is still picked up and the logged-in state is set as before.
- The modal should still open when the user explicitly asks to log in (the
  TopBar login/sign-up button, the account block in settings, the gallery
  login button, and any other existing explicit entry points).
- Make the modal dismissible: add a visible close / "Continue without an
  account" control, and let Escape and backdrop clicks close it, using the
  component's existing close handler.
- Update any existing tests (for example `login-modal.spec.tsx`) that
  assert the old auto-open behaviour, and add a test that a missing session
  does not open the modal. Run the affected frontend tests.

Do not remove login, the hosted ArtCraft provider, billing/credits, or the
cloud features. Logged-in behaviour should be unchanged. Do not change the
default generation provider or add new offline/local modes.

Add a bullet to the `## Differences from upstream` section of
`earlye-fork.md` (create the file with that section if it doesn't exist):
`feature-001` — the login modal no longer opens automatically at startup
and can be dismissed; features that need an ArtCraft account still prompt
for login.

Do not make any other changes.
