# Elm client — surface-when-we-come-up-for-air

Defers: noted in-session but not worth interrupting the current
zoom. Clear whenever a related pass is underway.

## Layout

- **Excess whitespace above the hand and board, pushing the
  board below the fold.** (Steve, 2026-04-21.) The top-of-page
  chrome / margins are eating vertical real estate; result is
  the 600px board partially clipping below the viewport. A
  flex-align + margin audit on the outer layout is the likely
  shape of the fix. Workaround: Steve scrolls, which is mildly
  annoying but not blocking gameplay.
