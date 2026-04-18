# Stock-Taking at the Two-Player Milestone

*Where we are, what we decided, what's left.*

---

## The short version

Two-player LynRummy works end-to-end under trust-server mode:

- **Go server** owns state, replay, rules, scoring, draw logic,
  hint enumeration, geometry enforcement, turn classification.
- **Python client** can drive a complete game via `/hints` +
  `/state`, including per-turn score observation.
- **Elm client** renders both hands (active face-up, opponent as
  card count), handles drag-drop for merges/place/move, submits
  CompleteTurn and receives the 5-branch result.

The port isn't finished, but the LOAD-BEARING MECHANICS are.
What's left is mostly UI completing the circle on visible
features Python already has server-side.

---

## Axioms we settled this session

These were implicit or wobbly before; now they're in memory as
named rules:

- **Shared board is the axiom.** Not cooperation. Friendly
  competition on one play surface.
- **Turn mechanics** serve social structure AND pragmatic
  accommodation. Solitaire mode is a fallback, not a design
  goal.
- **Trust-server mode first.** Server owns classification; Elm
  reads what the server says. Autonomous Elm comes later. This
  prevents drift while two clients catch up.
- **Python is lazy, not dumb.** Don't re-implement what Go
  computes (hints, scores, turn classification). But Python IS
  the UI substitute for the agent — it owns spatial placement,
  move selection, turn pacing.
- **Card aging is client-side display.** Derivable from the
  action log. Server doesn't track FreshlyPlayedByLastPlayer.
- **Seat is strict; user is permissionless.** Active hand changes
  only on CompleteTurn. Any user can drive the active seat.

---

## What's ported (subsystem breakdown)

### Go (authoritative)

- `State { Board, Hands, Deck, ActivePlayerIndex, Scores,
  VictorAwarded, TurnStartBoardScore, TurnIndex,
  CardsPlayedThisTurn }` — self-contained replay state
- 9 wire actions (split, merge_stack, merge_hand, place_hand,
  move_stack, draw, discard, complete_turn, undo, play_trick)
- `ApplyAction` / `ReplayActionsSeeded` — deterministic replay
  from action log + per-session seed
- `applyCompleteTurn` — classifies, banks turn score, draws 0/3/5
  for outgoing player, cycles seat, sets victor flag
- `ValidateTurnComplete` referee gate (geometry + semantics)
- Hint enumeration: `LegalHandMerges`, `LegalStackMerges`,
  TrickBag's `FindPlays`
- Scoring: `StackTypeValue` (PureRun=100, Set=60, RedBlackRun=50)
  per card + `ScoreForCardsPlayed(n) = 200 + 100n²` per turn
- Endpoints: /actions, /state, /score, /hints, /turn-log,
  /sessions, /sessions/:id, /new-session

### Python (agent)

- `client.py`: all 9 `send_*` methods + readers for state, score,
  hints, turn-log
- `greedy.py`: plays both seats via /hints, reports per-move +
  per-turn score summaries, respects turn cycling
- `undo_demo.py`: undo mechanic demo
- Reads `state.hands[active_player_index]` and `state.scores[i]`

### Elm (trust-server)

- Two-row player layout (active hand face-up + buttons; opponent
  shows card count only)
- Drag-drop gesture arbitration (click vs drag via 1px threshold,
  wing-based merge targeting, viewport-scroll-aware placement)
- CompleteTurn: chained flow (send → receive 5-branch → fetch
  authoritative state → update UI)
- Status bar with inform/celebrate/scold styling
- Session lobby: new game / resume session / browse
- Undo button (fire-and-forget + state refresh)

---

## What's left, by bucket

### Elm trust-server gaps (small, UI-shaped)

1. **Per-player score display** — currently shows a shared
   board-ish score on the active row. Move to a labeled per-row
   total read from `state.scores`.
2. **Hint button** — stub. Should call `/hints`, highlight hand
   cards, set a status message.
3. **Draw button** — stub. Sends `WA.Draw`.
4. **Per-action StatusBar messages** — "On the board!" after
   place_hand, "Combined!" after merge, "Nice and tidy!" on
   geometry transition crowded→clean.
5. **Victor celebration** — probably just a distinct status
   message; no popup modal in V1.

### Python agent gaps (strategic)

1. **Spatial placement.** Greedy sidesteps by only using merges;
   a smarter bot needs local rect math to pick locs for
   place_hand / move_stack. Python owns this.
2. **Strategic splitting.** Greedy never splits; could pay off.

### Dev-harness / process

1. **GESTURES.md glossary** — enumerate-and-bridge doc mapping
   wire action ↔ Elm function ↔ Python method. Deferred until
   we feel the naming drift biting.

### Future work (not blocking V1)

1. **Autonomous Elm mode** — Elm runs its own rules + ref, no
   server dependency for classification. Comes after trust-server
   mode is battle-tested.
2. **Real shuffled deals** — currently two canned hands of
   specific cards for reproducibility; eventually per-session
   deal from shuffled deck.
3. **Card aging in Elm** — FreshlyPlayed visual highlighting for
   opponent's recent plays. Pure display, derivable.
4. **Session label editing** — no API currently; neither client
   can do it.

---

## The three lenses for "V1 done"

At the end of each turn, the player should be able to:

1. **Complete the turn** via the Complete Turn button, and see
   the result (success / needs cards / hand emptied / victor).
2. **See both scores** updated in the UI — their own turn score
   banked, the opponent's unchanged.
3. **Hand off** — the UI swaps to show the opponent's hand
   face-up, their own face-down (count only), and the status
   message greets the new player.

All three work now under trust-server mode except: **(2) the score
display is still wrong on the Elm side** (shows board score
misattributed to the active player). That's the one remaining
functional gap. Everything else in the "Elm trust-server gaps"
list is polish.

---

## The framing question for final features

The dumbest possible ranking, if "V1 playable" is the goal:

1. Fix Elm score display (read `state.scores[i]` per row).
2. Hint button (+ status message when no hint available).
3. Per-action status bar messages.
4. Draw button.
5. Everything else in "future work."

Hint and Draw can be fire-and-forget like other actions — they
already exist on the server. Most of the work is Elm-side
cosmetic completion of functionality that's already real.

If you want the port to feel "done" to Susan, item 1 alone gets
us 80% there. Items 2–4 are confidence/polish.
