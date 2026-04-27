# LynRummy Elm — User Flows

Enumerated user-facing flows for the Elm client. Each flow is a
numbered sequence of atomic steps: what the user does, what the
client does, what the server does. If a step can be trivially
verified ("button exists and fires Msg X"), it's a step.

**How to use this doc:**

1. Before shipping a flow change, walk each step mentally. Does
   each one exist in the UI and in the code?
2. When a flow breaks, re-read the steps and find which one is
   failing.
3. When adding a new user action, write the flow here FIRST —
   then implement against it.
4. Keep steps small. "User clicks Hint button" is one step, not
   "User notices a hint button and clicks it."

**Status markers:**

- ✅ Wired end-to-end
- 🟡 Partially wired / known gap
- ❌ Stub only, does nothing

---

## Lobby

### 1. Start a new game

1. User clicks "Start new game" button. ✅
2. Client: `ClickNewGame` fires, model phase → Playing,
   sessionId stays Nothing, fetchNewSession fires. ✅
3. Server: POST /new-session creates a fresh session with a
   deck seed, returns `{session_id}`. ✅
4. Client: `SessionReceived` sets sessionId, fires
   setSessionPath port + fetchActionLog. ✅
5. URL path updates to `/gopher/lynrummy-elm/play/<sid>`. ✅
6. Server: GET /sessions/:id/actions returns
   `{initial_state, actions: []}` for the freshly-seeded deck. ✅
7. Client: `ActionLogFetched` runs `bootstrapFromBundle` —
   seeds Model from `initial_state`, folds the (empty) log
   through the local reducer, stashes `initial_state` as
   `replayBaseline`. ✅
8. UI shows two-row player layout, Player 1 active with 15
   cards face-up, Player 2 with "15 cards" line. ✅

### 2. Resume an existing session

1. User sees list of sessions in lobby with Resume buttons. ✅
2. User clicks Resume for session N. ✅
3. Client: `ClickResumeSession sid` fires. Model phase →
   Playing, sessionId set, fetchActionLog + setSessionPath. ✅
4. URL path updates to `/gopher/lynrummy-elm/play/<sid>`. ✅
5. Server: GET /sessions/:id/actions returns
   `{initial_state, actions: [...]}`. ✅
6. Client: `bootstrapFromBundle` seeds Model from
   `initial_state` then folds every action through
   `Main.Apply.applyAction` to reach current state.
   UI reflects progress. ✅

### 3. Reload a game in progress

1. User hits browser reload while playing session N. ✅
2. Page reloads; URL path is still `/gopher/lynrummy-elm/play/N`. ✅
3. Go server parses the path and bakes `initialSessionId: N`
   into the Elm flag in the rendered HTML. ✅
4. Elm init: phase → Playing, sessionId set, fetchActionLog +
   fetchSessionsList. ✅
5. UI resumes at current state. ✅
6. Ephemeral state (hint highlights, popup, status message) is
   lost. This is by design.

### 4. Back to lobby from a game

1. User clicks "← Lobby" button in turn controls. ✅
2. Client: `ClickBackToLobby` fires. Phase → Lobby, sessionId
   cleared, fetchSessionsList + setSessionPath "" (clear path). ✅
3. URL resets to `/gopher/lynrummy-elm/`. ✅
4. UI shows lobby with session list. ✅

---

## Board play (mid-turn, active player)

### 5. Place a hand card as a new stack on empty board space

1. User presses and drags a hand card. ✅
2. Client: `MouseDownOnHandCard` + fetchBoardRect. ✅
3. Drag state becomes Dragging; a floating copy follows cursor. ✅
4. User releases over an empty part of the board (no wing hover). ✅
5. Client: `MouseUp` / `resolveGesture` — no wing, `cursorOverBoard` true. ✅
6. Compute `loc = floaterTopLeft - boardRect` (viewport→board). ✅
7. `WA.PlaceHand { handCard, loc }` sent to server. ✅
8. Local model: card removed from active hand, new stack
   appended to board at loc. ✅
9. Server: persists action, next /state reflects the placement. ✅

### 6. Merge a hand card onto a stack's wing

1. User drags a hand card. ✅
2. User hovers over a stack's left or right "wing" (drop target). ✅
3. Wing highlights (mergeable green). 🟡 (verify — wing tint
   wiring should be correct)
4. User releases on the wing. ✅
5. Client: `WA.MergeHand { handCard, target, side }`. ✅
6. Local model: card removed from hand, target stack replaced
   by merged result. ✅

### 7. Move a stack to empty space

1. User drags a board stack. ✅
2. Floating copy follows cursor; wings of OTHER stacks show. ✅
3. User releases over empty space (no wing). ✅
4. Client: `WA.MoveStack { stack, newLoc }`. ✅

### 8. Merge a stack onto another stack's wing

1. User drags a board stack. ✅
2. Target stack's wing highlights on hover. ✅
3. User releases on the wing. ✅
4. Client: `WA.MergeStack { source, target, side }`. ✅

### 9. Split a stack

1. User clicks a non-first card in a board stack (click-vs-drag
   arbitration via 1px threshold). ✅
2. Click intent fires `WA.Split { stack, cardIndex }`. ✅
3. Local model: stack replaced by two smaller stacks. ✅

---

## Turn controls

### 10. Complete turn (ceremony flow — the big one)

1. User clicks "Complete turn" button. ✅
2. Client: local referee pre-check, then
   `applyAction WA.CompleteTurn` runs
   `Game.applyCompleteTurn` locally — seat cycles, hands
   refill, score banks, popup + status generated from the
   local `CompleteTurnOutcome`. ✅
3. Client: `sendCompleteTurn sid` fires fire-and-forget so
   the server persists the action. ✅
4. Server: replays, runs ValidateTurnComplete gate,
   classifies, banks turn_score, draws 0/3/5 cards, cycles
   seat, returns
   `{ok, seq, turn_result, turn_score, cards_drawn, dealt_cards}`
   (or 400 on failure). ✅
5. Client: `CompleteTurnResponded` logs the server's
   outcome as a divergence monitor against the locally-
   computed one. UI already reflects the local outcome. ✅
6. Popup (set in step 2) appears with the correct
   character and future-tense narration:
   - dirty board → Angry Cat scolds ✅
   - no cards played → Oliver sympathizes ✅
   - regular / hand-emptied / victor → Steve celebrates ✅
7. User clicks OK on the popup. ✅
8. Client: `PopupOk` clears popup. UI now shows incoming
   player's view (already flipped in step 2). ✅

### 11. Undo last action

Undo is deferred — V1 has no Undo button. The `WA.Undo`
variant exists in the wire format and `Main.Apply.applyAction`
handles it as a no-op for now.

### 12. Get a hint

Hint system rebuilt 2026-04-18. Current Elm wiring is a
placeholder; the Python client is the first consumer of the new
`/hint` endpoint. The Elm retrofit is pending.

**New flow (server side, live):**

1. User clicks "Hint" button. 🟡 (Elm shows placeholder message)
2. Client GETs `/gopher/lynrummy-elm/sessions/<id>/hint`.
3. Server calls `tricks.BuildSuggestions(hand, board)` which
   walks `HintPriorityOrder` (the seven tricks in simplest-first
   order: direct_play → hand_stacks → pair_peel → split_for_set →
   → peel_for_run → rb_swap → loose_card_play). First play per
   firing trick becomes a `Suggestion`.
4. Returns `{ "suggestions": [{rank, trick_id, description,
   hand_cards, action}, ...] }`.
5. Client picks `suggestions[0]` as the top hint, uses `action`
   directly as a POSTable wire action.
6. Status bar shows the description. 🟡 (pending Elm retrofit)
7. Hand cards from `hand_cards` get highlighted in green. 🟡
   (pending Elm retrofit)

**Design principles** (see `showell/claude_writings/hints_from_first_principles.md`):
- Priority is processing order, not a score metric.
- Server over-shares; client filters.
- One representative play per firing trick.
- `direct_play` is the beginner-favorite.

---

## Known UI gaps (from walking the flows)

- Flow 11 (Undo) — works, but no popup ceremony — deliberate for
  now.
- Flow 6 step 3 (wing hover green tint) — unverified from
  screen; code is wired but visual confirmation pending.

## Not user actions in LynRummy

- **Draw** — there's no user-initiated draw. The dealer adds
  cards to the outgoing player's hand at CompleteTurn based on
  the 5-branch result (0/3/5). This is Flow 10, not a
  separate flow.
- **Discard** — no discarding in LynRummy. Cards leave the hand
  only by being placed on the board (place_hand / merge_hand).

The `WA.Draw` and `WA.Discard` wire actions and server
handlers still exist — Python's greedy.py uses `send_draw` at
turn start. Worth revisiting whether these should be ripped
from the wire format entirely, since the Elm UI has no path to
them and they predate the current turn-draw model.

---

## Change discipline

When a user flow changes:

1. Update this doc FIRST.
2. Walk each step, verify it's wired.
3. Implement / fix code to match.
4. Re-walk.

When adding a new action:

1. Add a new numbered flow here.
2. Note the initiating UI element (button / drag / click).
3. Note the wire action it produces (or that it's UI-only).
4. Note the server response shape if relevant.
5. Note any follow-up state refresh.

A flow is "done" when every step is marked ✅ and the sequence
walks end-to-end without silent failure.

---

See: [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — cited from
the architecture doc's "Where to find more" section.
