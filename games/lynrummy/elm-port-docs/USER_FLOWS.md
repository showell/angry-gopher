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
   setSessionHash port + fetchRemoteState. ✅
5. URL hash updates to `#<sid>`. ✅
6. Server: GET /state returns initial board + both hands + seat 0. ✅
7. Client: StateRefreshed populates hands/board/scores/active. ✅
8. UI shows two-row player layout, Player 1 active with 15
   cards face-up, Player 2 with "15 cards" line. ✅

### 2. Resume an existing session

1. User sees list of sessions in lobby with Resume buttons. ✅
2. User clicks Resume for session N. ✅
3. Client: `ClickResumeSession sid` fires. Model phase →
   Playing, sessionId set, fetchRemoteState + setSessionHash. ✅
4. URL hash updates to `#<sid>`. ✅
5. Server: GET /state replays action log, returns current state. ✅
6. Client populates UI — active hand + scores reflect progress. ✅

### 3. Reload a game in progress

1. User hits browser reload while playing session N. ✅
2. Page reloads; URL hash is still `#<sid>`. ✅
3. Harness script parses hash, passes `initialSessionId: N`
   as Elm flag. ✅
4. Elm init: phase → Playing, sessionId set, fetchRemoteState +
   fetchSessionsList. ✅
5. UI resumes at current state. ✅
6. Ephemeral state (hint highlights, popup, status message) is
   lost. This is by design.

### 4. Back to lobby from a game

1. User clicks "← Lobby" button in turn controls. ✅
2. Client: `ClickBackToLobby` fires. Phase → Lobby, sessionId
   cleared, fetchSessionsList + setSessionHash "" (clear hash). ✅
3. URL hash clears. ✅
4. UI shows lobby with session list. ✅

---

## Board play (mid-turn, active player)

### 5. Place a hand card as a new stack on empty board space

1. User presses and drags a hand card. ✅
2. Client: `MouseDownOnHandCard` + fetchBoardRect. ✅
3. Drag state becomes Dragging; a floating copy follows cursor. ✅
4. User releases over an empty part of the board (no wing hover). ✅
5. Client: `MouseUp` / `resolveGesture` — no wing, `cursorOverBoard` true. ✅
6. Compute `loc = cursor - grabOffset - boardRect` (viewport-relative). ✅
7. `WA.PlaceHand { hand_card, loc }` sent to server. ✅
8. Local model: card removed from active hand, new stack
   appended to board at loc. ✅
9. Server: persists action, next /state reflects the placement. ✅

### 6. Merge a hand card onto a stack's wing

1. User drags a hand card. ✅
2. User hovers over a stack's left or right "wing" (drop target). ✅
3. Wing highlights (mergeable green). 🟡 (verify — wing tint
   wiring should be correct)
4. User releases on the wing. ✅
5. Client: `WA.MergeHand { hand_card, target_stack, side }`. ✅
6. Local model: card removed from hand, target stack replaced
   by merged result. ✅

### 7. Move a stack to empty space

1. User drags a board stack. ✅
2. Floating copy follows cursor; wings of OTHER stacks show. ✅
3. User releases over empty space (no wing). ✅
4. Client: `WA.MoveStack { stack_index, new_loc }`. ✅

### 8. Merge a stack onto another stack's wing

1. User drags a board stack. ✅
2. Target stack's wing highlights on hover. ✅
3. User releases on the wing. ✅
4. Client: `WA.MergeStack { source_stack, target_stack, side }`. ✅

### 9. Split a stack

1. User clicks a non-first card in a board stack (click-vs-drag
   arbitration via 1px threshold). ✅
2. Click intent fires `WA.Split { stack_index, card_index }`. ✅
3. Local model: stack replaced by two smaller stacks. ✅

---

## Turn controls

### 10. Complete turn (ceremony flow — the big one)

1. User clicks "Complete turn" button. ✅
2. Client: `ClickCompleteTurn` fires `sendCompleteTurn sid`. ✅
3. Server: replays, runs ValidateTurnComplete gate, classifies,
   banks turn_score, draws 0/3/5 cards, cycles seat. ✅
4. Server response: `{ok, seq, turn_result, turn_score, cards_drawn}`
   (or 400 `{ok:false, turn_result:"failure", ...}`). ✅
5. Client: `CompleteTurnResponded` sets
   `popup = Just (popupFromOutcome outcome)` and a status-bar
   message. ✅
6. Popup appears with the correct character and future-tense
   narration:
   - dirty board → Angry Cat scolds ✅
   - no cards played → Oliver sympathizes ✅
   - regular / hand-emptied / victor → Steve celebrates ✅
7. UI visual state does NOT flip yet — still shows outgoing
   player's view. ✅
8. User clicks OK on the popup. ✅
9. Client: `PopupOk` clears popup, fires `fetchRemoteState`. ✅
10. Server: returns post-turn state. ✅
11. Client updates active seat, hands, scores. UI flips. ✅

### 11. Undo last action

1. User clicks "Undo" button. ✅
2. Client: `ClickUndo` → `sendAction sid WA.Undo` + fetchRemoteState. 🟡
   (Note: no popup, no status message beyond "Undone." — could
   grow ceremony later)
3. Server: persists an Undo action. Replay's EffectiveActions
   cancels the last non-Undo action. ✅
4. Client refetches state, UI reverts. ✅

### 12. Get a hint

1. User clicks "Hint" button. ✅
2. Client: `ClickHint` → `fetchHints sid`. ✅
3. Server: GET /hints returns hand_merges + stack_merges +
   trick_plays arrays with `result_score` previews. ✅
4. Client: decoder normalizes to `List HintOption`. ✅
5. Client: `pickBestHint` returns the max-score option. ✅
6. Status bar shows the hint's description. ✅
7. `model.hintedCards` is set to the hint's hand cards. ✅
8. Hand cards in `hintedCards` render with a lightgreen
   background. ✅

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
