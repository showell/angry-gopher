# HINT_SOPHISTIFICATION

**Status:** ACTIVE (2026-07-05). Class (A) rendering is SHIPPED and live;
the first slice of (B) — plan *ordering* — is done (the `compressHint`
humanizer, 2026-07-04 block below). The 2026-07-05 work below adds a
second, deeper slice of (B): **scoping the hint to the player's focus via
a last-move "loner" flag**, so a just-placed hand card gets finished with
board cards instead of bundling in an unrelated play. Read the 2026-07-05
block, then the 2026-07-04 block; both supersede the ORIGINAL 2026-05-05
roadmap kept at the bottom as the map for remaining work.

---

## 2026-07-05 progress — the "loner" flag (board-first when finishing your own placement)

### The problem it fixes

Real seed-42 game-2 mid-turn (uid 16): the player laid a `2♠` from hand
onto an empty spot, then hit Hint expecting the two easy peels that finish
a set of 2s. Instead the engine returned a **bundled four-line plan** —
it projected `[8♥ 9♣]` from hand and welded in an unrelated `8-9-T` run
alongside the forced `2♠` cleanup.

**Root cause (Steve's diagnosis, not "the solver is greedy"):** the code
projected *new* hand cards onto a board already dirty from a card we
ourselves placed. `findLogicalMovesForPlay` always projected ≥1 hand card
(singleton→pair) and never tried the empty projection — finishing the board
with **no new card**. The dirty-board contract then forced `solveBoard` to
also resolve the pre-existing `2♠`, welding the two independent threads
into one plan.

**The nuance that makes it correct:** finishing the `2♠` with board cards
is *progress* only because the `2♠` is a **hand-origin loner** — melding it
commits a hand card. If it had been split out of a board group, "cleaning"
it would commit zero hand cards and could *reverse* progress (undo the
split, or abandon the maneuver it served). So provenance matters, and the
board+hand snapshot alone doesn't carry it.

### The design (stateless solver, one fact from Elm)

The solver stays a pure function of a board snapshot — it does NOT replay
history. **Elm owns the move timeline and distills it to one boolean.**
`Lib.ActionLog.lastMoveWasHandLoner`: collapse undos, ignore cosmetic
`MoveStack` repositions, and report whether the last *structural* action
was a `PlaceHand` (a hand card laid onto an empty spot). That rides the
`game_hint` port as `loner` → glue `req.loner` → `elmGameHint` →
`gameHintLines` → `findLogicalMovesForPlay(hand, board, handLonerPlaced)`.

A **bare boolean is enough** (Steve's call): the solver can only sign off a
play when *every* stack ends legal, so `solveBoard` fails on its own if the
loner can't be melded (or melding strands another card) — no need to
identify the specific loner.

When the flag is set, `findLogicalMovesForPlay` first tries `boardOnlyPlay`
(= `solveBoard(board)`, no projection, `cardsToPlay = []`). On success that
*is* the hint; `formatHint` drops the `place […] from hand` line for a
zero-new-cards play. The game-2 hint is now just:

```
peel 2♣ from 2♣ 3♦ 4♣ 5♥ 6♠ onto 2♠
peel 2♥ from 2♥ 3♥ 4♥ 5♥ onto 2♣ 2♠
```

### 2026-07-05 later — the wholesale-merge pre-pass (before anything merits "solve")

Same game-5 session, later position: trouble pair `[8♠' 9♦']` next to the rb
run `[3♦ 4♣ 5♥ 6♠ 7♥]`. The depth-1 frontier contains two one-move wins —
push the pair wholesale onto the run (human: 9 stacks, one 7-card run), or
peel the 7♥ off the run onto the pair (10 stacks, the healthy run shaved).
The trouble-greedy solve returned the peel purely because extract_absorb
generators enumerate before push and plan length is the only ranking; the
trouble frame is symmetric about *who donates to whom*, humans are not (the
broken thing moves onto the good structure, never the reverse unless forced).

Fix (Steve's design): treat the human play as OUT OF SCOPE of the solve.
When the loner flag is set, `wholesaleMergePlay` (hand_play.ts) runs FIRST:
a greedy fixpoint loop merging each incomplete stack wholesale onto a
complete group (either end). If that alone leaves the board fully clean,
the merge list IS the hint; anything short discards entirely and falls
through to `boardOnlyPlay` → solve (all-or-nothing, never half-applied).
The merges are genuine push Moves rendered via `describe()` — one authority
for the line format, no new DSL verb, nothing new across the TS↔Elm seam
(the hint reply stays a list of DSL strings). compressHint's existing push
rule already humanizes the multi-card loose group:
`push 8♠ 9♦ onto 3♦ 4♣ 5♥ 6♠ 7♥`.

Pinned: `hint_dirty_board.dsl` scenario `loner_pair_merges_wholesale_onto_run`
(the real position; fails against the solver's peel without the pre-pass) +
`hint_compress.dsl` `board_only_pair_push` (the seam pin for the pair-push
line). Agent path unaffected (`play.ts` passes `loner=false`).

**Refinement (same day): trouble+trouble joins come FIRST.** Next real
game-5 position: trouble `[K♠ A♦]` + `[2♠]` — which complete each other
(the wrap run) — and the pre-pass instead dragged both onto the healthy
`[3♦ 4♣ 5♥ 6♠]` run because its targets were scoped to complete groups.
Each greedy pass now tries trouble+trouble before trouble→helper. Only a
COMPLETE result counts — two loose cards are never merged into a
still-troublesome pair (they may have been split for good board-wide
reasons, per Steve); the only completable shape is single+pair = the
engine's `free_pull` (`pull 2♠ onto K♠ A♦`). Pair+pair→4 has no verb and
no real case — invisible, falls to the solver. Pinned:
`loner_trouble_pair_and_singleton_complete_each_other` +
`board_only_pull_completes`.

### DEFERRED (by Steve, deliberately) — the loner that NEEDS a hand card

If board-only *fails* (the loner genuinely can't complete without a hand
card), we currently **fall through to today's projection** — non-regressive,
no new logic. The smart, scoped hand-card completion is **not built yet**:
per Steve, don't write speculative fallback logic that no test drives. When
a real position surfaces where a placed loner needs a hand card, THAT
becomes the failing test that drives the scoped fallback (and possibly a
`shift`/`decompose`-aware variant). Until then it stays deferred.

### Where it lives / tests / commits

- Engine: `ts/plan/hand_play.ts` (`handLonerPlaced`, `boardOnlyPlay`,
  `formatHint` skip-place-line). Threaded through `elm_api/engine_entry.ts`
  and `elm/engine_glue.js` (`req.loner`, defaults false).
- Elm: `elm/src/Lib/ActionLog.elm` (`lastMoveWasHandLoner`),
  `Lib/Engine.elm` (`buildGameHintRequest` gains the bool),
  `Game.elm` (ClickHint computes it from `model.actionLog`).
- Tests (test-first, red→green): conformance gained a `loner:` field;
  `conformance/scenarios/hint_dirty_board.dsl` scenario
  `loner_2s_finished_with_board_cards` (fails without the flag). Elm
  `tests/Lib/ActionLogTest.elm` pins the flag logic (6 cases).
- Commits: `fb7688b4` (TS core, test-first) · `d72c01cf` (Elm sends it).
  Nothing deployed — awaits Steve's sign-off.

### Gotcha logged (don't repeat)

The front-end bundles (`elm.js`, `engine.js`) are `@embedFile`'d into the
zig binary. Rebuilding them on disk does NOTHING for a running server —
`ops/start` rebuilds bundles, `zig build` re-embeds, and restarts. A
browser hard-reload can't fix a stale embed. Verify after with the served
bytes / binary (`grep -ac <token> zig-server/zig-out/bin/zig-server`).

---

## 2026-07-04 progress — the hint humanizer (`compressHint`)

### What now happens

A raw engine hint is a list of DSL plan-step lines led by a
`place [X] from hand` step, e.g. (seed-42 turn_3, a dirty mid-turn board):

```
place [4♣'] from hand
peel K♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [J♦' Q♦' K♦] [→COMPLETE]
push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
splice [4♣'] into HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] → [2♣ 3♦ 4♣'] + [4♣ 5♥ 6♠ 7♥]
```

`compressHint` now rewrites that into the sequence a human would perform:

```
peel K♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦
push 4♠ onto K♠ A♠ 2♠ 3♠
splice 4♣ from hand into 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
```

Two transformations, both driven by the insight Steve articulated: **the
projection layer that lays hand cards onto the board is order-blind, but a
human drops a hand card only when the board is ready for it.**

1. **Board-first reorder + fuse the hand landing (was Class A + start of B).**
   The `place [X] from hand` step is deferred and *fused* with the one move
   that actually consumes X (a single UI drag, not two). Every OTHER move is
   board→board manipulation and floats to the front, in the solver's order.
   So the hand card lands LAST, after board prep.
2. **Humanize each line** — strip the algorithm decoration: `HELPER`,
   brackets, `→ [result]`, `[→COMPLETE]`, `; spawn ...`, and the deck-2
   apostrophe (`A♠'` reads as `A♠`; the two physical decks are identical to
   the eye — but deck STILL matters for the place==consume identity check).

### Verb vocabulary (all decisions ratified by Steve)

| engine verb(s) | as a HAND landing | as a BOARD move |
|---|---|---|
| `push` | `play X from hand onto <grp>` | `push X onto <grp>` |
| `free_pull` | `play X from hand onto <grp>` | `pull X onto <grp>` |
| `splice` | `splice X from hand into <run>` | `splice X into <run>` |
| `peel`/`pluck`/`yank`/`steal` | — (never a hand landing) | `<verb> X from <src> onto <tgt>` |
| `set_peel` | — | `peel X from <src> onto <tgt>` |
| `split_out` | — | `split out X from <src> onto <tgt>` |
| triple-in-hand (no move) | `play X Y Z from hand` | — |

- `push`/`free_pull` unify to **"play … from hand onto"** for the hand case
  (the helper-vs-partial distinction is invisible to the player); they stay
  distinct **push/pull** for board cleanups.
- Keep verbs players recognize (`splice`, `peel`, `yank`, `steal`) rather than
  flattening to a generic "move" — Steve's call. `set_peel`/`split_out` are
  internal names → natural substitutes.
- Deliberately NOT shown: that a splice divides a run into two; that
  steal/yank leave `spawn` cards loose. The player watches those happen. (Both
  were flagged to Steve; he agreed to omit.)

### Honesty guardrail

Any plan `compressHint` does not *fully* understand is returned **entirely
raw** — never half-transformed. That covers: an unhandled verb
(`decompose`), or a `place [X]` whose card no move lands. All-or-nothing per
hint.

### Where it lives / how it's tested / wired

- **Module:** `ts/plan/hint_compress.ts` — `compressHint(lines) → lines`.
  Works entirely in DSL space; card lists round-trip through the shared
  `dsl/parse.ts` + `dsl/emit.ts` (the `canon` helper) so output is canonical
  DSL. Line structure is matched with per-verb regexes.
- **Wired:** `formatHint` (`ts/plan/hand_play.ts`) runs its assembled lines
  through `compressHint`. Path to the real game: Elm `Game.elm` Hint button →
  `engineRequest` (op `game_hint`) → `elm/engine_glue.js` → `elmGameHint`
  (`ts/elm_api/engine_entry.ts`) → `gameHintLines` → `formatHint` →
  `compressHint`. Game.elm shows all lines joined (status bar). **Verified
  live** in the `:9001` binary (the bundled `engine.js` embeds it).
- **Tests (DSL-in / DSL-out, the contract):**
  `conformance/scenarios/hint_compress.dsl` + `test/test_hint_compress.ts`
  (registered in `ops/test_ts`), 18 scenarios: push/splice/free_pull fusions,
  all six extract_absorb verbs (real `describe()` inputs, spawn/COMPLETE
  present & absent), the two reorder cases (turn_2, turn_3), triple-in-hand,
  and two bail cases. Also re-pinned the engine-conformance hint fixtures
  (`hint_game_seed42.dsl` turn_1/2/3) to the new output; engine 167/167.

### Commits (2026-07-04)

`cd4a5b8c` puzzle Hint button · `cdfa3842` compressHint push fusion (DSL→DSL)
· `7b3eba3b` wire into formatHint + humanize · `8d3f298a` splice + free_pull
· `3dbb88c5` "splice" as the verb · `1a7a3960` extract_absorb 1→1 ·
`6de28049` plan-global board-first reorder.

### What's LEFT (maps onto the original A/B/C below)

- ~~`shift`~~ **DONE 2026-07-06** (`33cb9912`): humanized as one compound
  line — `shift 5♠ into 6♦ 7♠ 8♥, freeing the 8♥ onto 9♥ T♥` (phrasing
  Steve's; real game-5 board-only plan whose shift had been blocking the
  whole hint from humanizing). `decompose` — still not humanized; plans
  touching it bail to raw.
- **Pairs that split** — a `place [X Y]` consumed by a `decompose` then two
  landings. Current scope is a SINGLE hand card consumed by one move (a pair
  pushed *as a unit* already works).
- **Class (B) strategic ranking** and **Class (C) KICK** — untouched; the
  reorder only handles *ordering*, not *which* plan the engine picks. See
  below. NB the 2026-05-05 calibration already downgraded (C).
- **Reorder assumption:** ~~board moves are independent of the hand card, so
  hand-last is safe~~ — **falsified 2026-07-05** (Stephen2 game 5: two loners,
  the solver landed 9♥ on the T♠' mid-plan, then pulled the 8♠' onto the
  *result*; floating that pull ahead told the player to pull onto a group that
  didn't exist yet). Fixed by fusing IN PLACE: moves keep the solver's order
  (executable by construction) and the landing move renders as the hand line
  at its own position. Hand-lands-last still falls out naturally whenever the
  solver sequences it last — which is every previously-pinned fixture.

### Landscape note — generating hard fixtures (Steve, 2026-07-04)

The interesting "hand card needs *significant* board prep" cases are inherently
DIRTY boards (a clean board + one hand card either fits directly or falls to a
pair). Hard **puzzles** are exactly such boards, but all-on-board with no hand.
To mint a game scenario from a puzzle, **lift some board cards back into a
hand** — the *inverse of the projection layer* (which today pushes hand cards
onto the board). Same operation, run backwards. Promising generator for both
playtest positions and reorder fixtures with multi-step prep. Not built.

---

## What this is (ORIGINAL ROADMAP — 2026-05-05)

`TS_ELM_INTEGRATION` Phase 1 routed the full-game Hint button
through the canonical TS engine — the same engine self-play
uses. The integration itself works: hints are
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
to lower the BFS plan to the same primitive sequence the
full-game loop would execute, then describe each primitive as
one human-action line.

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

## 2026-05-05 update — calibration shifted

Today's seed-42 turn-10/11 stuck-state experiment changed how
much weight each class deserves:

- **Class (C) is less urgent than originally framed.** The two
  worked stuck states (turn 10 with `[TS']`, turn 11 with
  `[8S]`) looked like KICK candidates from outside but solved
  cleanly with depth-5 BFS using only the existing verb
  library (yank / steal / pull / push / peel / split_out). The
  bottleneck was `HINT_MAX_PLAN_LENGTH=4`, not a missing verb.
  Bumped to 5 in commit `2d1d804`. Re-evaluate (C) only when a
  case surfaces that genuinely needs helper→helper KICK and
  doesn't fall to the existing verbs at any reasonable depth
  — the standing test case is `complicated_7D-example.json`.
- **Class (B) gained a new design direction from Steve**
  (random270.md ¶23): persist computed hint primitives in
  memory until the human's actual move diverges from them,
  rather than recomputing each step. "Focus on getting the
  model right." This is hint-persistence — a separable layer
  above `findPlay`, orthogonal to BFS. Might subsume some of
  what (B) was originally going to do via candidate ranking,
  since persistence-of-earned-knowledge IS a strategic-
  awareness mechanism.
- **Class (A) unchanged.**

Net effect on ordering: (A) still first (unchanged). (B) shifts
toward "hint persistence" first, "candidate-set / ranking"
later. (C) drops from "design with B" to "wait for a real case."

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
- `games/lynrummy/ts/plan/hand_play.ts` — `findLogicalMovesForPlay`,
  `formatHint`, the dirty-board contract. The TS surface (A),
  (B), and (C) all touch.
- `games/lynrummy/ts/bfs/engine_v2.ts` — the BFS engine and
  verb-generator dispatch. (C) extends here.
- `claude-steve/MINI_PROJECTS.md` — current project index.
