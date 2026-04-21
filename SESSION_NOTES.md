# Session notes — 2026-04-21

## MAJOR PIVOT: step back to layout fundamentals

We were executing Plan A (thin vertical slice for the 7H → 7-set
replay). Three viewport-coordinate drifts surfaced that trace to
the same root cause: I pinned containers but didn't pin the
content inside them.

Rather than patch with "constants-absorb-the-drift," Steve
flagged the pattern: before working around a constraint, verify
it's real. The "stuff above the board is making calculations
brittle" is a symptom — what IS the actual layout constraint the
browser is placing on us, and is it a real constraint or a
convention we inherited?

Today's budget permits a deep investigation of the layout
concepts before writing any more code. No further Plan A coding
until we have a shared understanding of:

1. Browser positioning primitives and their reference frames.
2. What forces content to flow above/beside a pinned region.
3. Scroll vs. no-scroll behavior inside pinned containers.
4. Minimum CSS needed for the kind of pinning we want.

Investigation essays live under
`/home/steve/showell_repos/claude-collab/users/steve/general/`
and are annotated by Steve in the browser.

## In-flight state

- Plan A code is committed through `3bfb444` — the pinned layout
  via `position: fixed`. Three drifts identified:
  - `HandLayout.handLeft = 30` vs actual hand gutter at viewport
    x=20 (10px off).
  - `boardViewportTop = 100` but real board rect ~150 because of
    `viewBoardHeading` + margins inside `boardColumn`.
  - `viewHand`'s `position: relative` container flows below
    Turn label + viewPlayerRow, so its viewport position is
    flow-dependent.

Don't "fix" these via constant adjustments until the pivot
investigation is done.

## Memory / framing references

- `feedback_simplify_before_patching.md` — this pivot IS
  simplifying; the drift fixes would have been patches.
- `feedback_own_the_whole_system.md` — we control the browser
  layout; the constraint question is "what's intrinsic to the
  browser" vs "what did we choose."
- `feedback_record_facts_decide_later.md` — related: viewport
  coords are facts, not interpretations; the layout should
  ENFORCE them, not negotiate them via drift.
