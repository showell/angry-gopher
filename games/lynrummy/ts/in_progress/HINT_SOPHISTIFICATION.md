# HINT_SOPHISTIFICATION

**Status:** QUEUED. Tabled while TS_ELM_INTEGRATION wraps up
its closing-out / docs cleanup pass. Resume after that.

**As of:** 2026-05-05.

## What this is

`TS_ELM_INTEGRATION` Phase 1 routed the full-game Hint button
through the canonical TS engine — the same engine the puzzle
agent uses. The integration itself works: hints are
correct, the dirty-board contract is enforced, the legacy Elm
BFS port retired. Real-game testing then exposed three classes
of *sophistication gap* — places where the engine's hints are
correct-but-clumsy compared to what a thoughtful human player
would do. This project is the work to close those gaps.

The original informal name was HINT_REFINEMENT. We rename it
HINT_SOPHISTIFICATION to acknowledge that the issues are about
how sophisticated the engine's *strategic reasoning* is, not
just polishing rendered text.

## The three classes of gap

### (A) Rendering

The hint plan is correct, but its description doesn't match the
motions a player will actually perform.

- **"place [a b] from hand"** reads as one motion but is two UI
  actions: the player drops `a`, then drops `b` onto `a`.
- **"place X from hand"** + **"splice X into [helper]"** reads
  as two motions but is one UI action — a direct hand→helper
  drop. The agent itself executes this as a single
  `merge_hand` per R1; the hint phrasing should follow.

The fix lives in `formatHint` (or a sibling). It probably wants
to lower the BFS plan to the same primitive sequence
`agent_player.ts` would execute, then describe each primitive
as one human-action line.

This class is fully separable from (B) and (C). It changes
*how* hints read, not *which* hint the engine picks.

### (B) Strategic awareness

`findPlay` evaluates each hint call as a fresh projection over
a snapshot board. It has no concept of "I'm partway through a
play." Manifestations:

- **No preference for completing existing partials** — the
  engine will recommend playing a fresh hand card that creates
  a new partial chain over the one-step consolidation that
  finishes a partial already on the board. The dirty-board
  example showed this.
- **No "do nothing this turn" option** — `findPlay` always
  projects at least one hand card. On a clean board with a
  small hand, the right answer may be "play nothing; end the
  turn."
- **No structural-cost ranking** — `findPlay` picks by
  `plan.length` only. Two plans of equal length can have
  wildly different structural cost (one tears apart a length-6
  helper; the other adds to a clean end). The complicated-7D
  example demonstrated this.

The fix is in `findPlay`'s candidate enumeration + ranking:
- **Add candidate classes**: board-only cleanups (no hand
  projection), and possibly "complete-this-existing-partial"
  candidates that aren't blind hand projections.
- **Replace shortest-plan tie-breaking with a richer score**:
  plan length + hand-size delta + helpers disturbed +
  completes-vs-creates-partials.

### (C) The KICK verb (helper → helper transfer)

The BFS verb library — `extract_absorb` (peel/pluck/yank/steal/
split_out), `free_pull`, `push`, `splice`, `shift`, `decompose`
— is "greedy by design": every frontier expansion has to touch
trouble. **Pure helper → helper card transfers don't appear in
the library.** Steve's term for them is **KICK**: an end card
of one helper is moved directly into another helper, leaving
the source helper shortened (still legal, length-N+) and the
target helper extended (also still legal). No trouble is
created or consumed; the move is "free" in the trouble-
reduction frame.

But kicks unlock plays. The complicated-7D example: a single
kick of `7H` from `[2C 3D 4C 5H 6S 7H]` into `[7S 7D 7C]`
shortens the long run to `[2C 3D 4C 5H 6S]`, which then
accepts `7D'` from hand in one push. Without KICK, the engine
finds an equivalent end-state via a 3-step yank-rebuild that
tears apart the same long run from the middle. Same outcome,
much higher structural cost.

The design tension: pure helper→helper rearrangement, if
generated unconstrained, blows up the search space. Some kind
of guardrail is essential. Sketches:

- **Targeted KICK**: only generate a kick if it *immediately*
  enables a hand-card placement or partial completion. The
  search isn't "what helper rearrangements are possible?" but
  "what specific hand card needs which end-card moved out of
  the way?"
- **Pre-search pass**: identify hand cards that are *one kick
  away* from fitting cleanly into a helper, and consider those
  kicks as setup moves before launching the main BFS.
- **Recognition pattern**: "this hand card would slot into a
  length-N run if its current end-card were elsewhere" —
  detected as a board property, not enumerated.

(B) and (C) are coupled. Adding KICK to the candidate set
changes which plays the engine surfaces; ranking decides which
candidate wins. Designing them independently would re-couple
them at integration time.

## Captured examples

Two captures live in this directory and serve as concrete test
cases for the design work:

- **`dirty_board_example.json`** — game 8 mid-turn 1, after
  9 hand-card placements. Board is dirty: `[8S']` singleton +
  `[6S' 7S']` partial. Engine produces a 5-step hint that's
  correct but heavy. Demonstrates the (B) "no awareness of
  in-progress partials" issue.
- **`complicated_7D-example.json`** — game 8 mid-turn 1, after
  13 hand-card placements. Board is clean. Engine produces a
  3-BFS-step hint that yanks 6S from the middle of a length-6
  helper. Steve's two-motion solution is structurally simpler
  but BFS-invisible (pure helper→helper kick). Demonstrates
  the (C) verb-library blind spot.

Both captures include the verbatim engine output, the state at
hint time, the player's actual solution where applicable, and
open questions. They should be the basis for the design pass
on (B) and (C) — both as test cases and as worked examples for
intuition.

More captures will accumulate here as testing continues. The
`run_hint.ts` one-off in this directory loads a captured state
and prints the engine's current `gameHintLines` output —
useful for re-running hints after engine changes to verify
captured cases drift in the expected direction.

## Recommended ordering when this resumes

Per `claude-steve/random267.md`:

1. **Ship (A) rendering first.** Small, separable, low-risk,
   immediately user-visible. Makes every subsequent
   observation cleaner because the engine's choices read at
   the same granularity as the player's gestures.
2. **Design (B) and (C) together** against a thicker corpus
   of captured examples. They share a candidate-enumeration +
   ranking layer; designing in isolation re-couples them at
   integration. Wait until the corpus has 5+ captures.
3. **Implement (B) and (C) in one design pass.** New
   candidate classes (board-only cleanup, kick-enabled plays)
   plus a richer ranking score. KICK guardrails (targeted vs
   pre-search-pass vs recognition pattern) are the open
   design question.

Open to talking through the ordering when this resumes —
nothing is locked in.

## Cross-references

- `claude-steve/random265.md` — the original Phase 1 contract
  proposal. Useful for grounding the integration shape this
  project builds on.
- `claude-steve/random266.md` — analysis of the dirty-board
  example, including a longer treatment of (B)'s strategic
  insights.
- `claude-steve/random267.md` — the framing essay this
  project doc summarizes. Read it for the longer reasoning
  behind the (A)-first recommendation.
- `games/lynrummy/ts/src/hand_play.ts` — `findPlay`,
  `formatHint`, the dirty-board contract. The TS surface (A),
  (B), and (C) all touch.
- `games/lynrummy/ts/src/engine_v2.ts` — the BFS engine and
  verb-generator dispatch. (C) extends here.
- `claude-steve/MINI_PROJECTS.md` — current project index.
