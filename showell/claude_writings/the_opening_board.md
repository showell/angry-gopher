# The Opening Board

*Written 2026-04-17 (late pm). Status report on the LynRummy UI port. Names the next milestone and how Steve helps.*

**← Prev:** [Inventory of a Partial Port](inventory_of_a_partial_port.md)

---

Status report, not retrospective.

## Where we are

Five modules ported today. All via sidecar-first after the
second one; zero post-port sidecar revisions needed so far
(speculated divergences have matched actual ones cleanly).

| Module | TS LOC | Elm LOC | Tests added | Sidecar |
|---|---|---|---|---|
| `core/score.ts` | 51 | ~70 | +20 | retro |
| `core/board_physics.ts` | 70 | ~90 | +13 | retro |
| `game/player_turn.ts` | 87 | ~90 | +13 | pre-port |
| `game/board_actions.ts` | 119 | ~160 | +12 | pre-port |
| `game/place_stack.ts` | 138 | ~130 | +11 | pre-port |

Cumulative tests: 207 → 276. All green. Commits ad0c6c5 through
bad8141, pushed to `origin/master`.

Each ported module:

- Has a companion `.claude` sidecar at the same path (WORKHORSE
  labels across the board).
- Has a dedicated `LynRummy/<Name>Test.elm` covering every
  public function.
- Is wired into `check.sh`'s `LYNRUMMY` list so it compiles
  standalone and can't bit-rot under a host-shell change.

## What's still unported

From the MVP scope I set earlier:

- `game/drag_drop.ts` (259 LOC) — I'm proposing we **skip
  the standalone port**. It's tightly coupled to DOM event
  listeners + `clientX`/`clientY` reads + element style
  mutation; in Elm, drag becomes a `DragState` variant inside
  the game Model plus `Msg`s for mousedown/move/up. Porting
  it as a standalone Elm module would produce a thing with no
  natural consumer — it wants to be inlined into the UI code
  it serves.
- `game/game.ts` (3046 LOC) — the real remaining work. State,
  turn logic, event handling, most of the UX. Will decompose
  into several Elm modules; a state-flow audit is the right
  next deliverable per the porting cheat sheet, but we can
  defer that audit until after we have something visible on
  screen.
- `plugin.ts` → `Main.elm` (TEA bootstrap). New file, not a
  port — just standard Elm entry-point shape.

Server-coupled modules (`wire_validation.ts`,
`protocol_validation.ts`, `gopher_game_helper.ts`) are fully
deferred to V2 per the standalone-first ruling.

## Next checkpoint: the opening board

Minimum visible result. What I propose to build next:

1. **A hardcoded initial board state.** Six to nine card
   stacks at specific positions, constructed directly in Elm
   using the already-ported `CardStack` types. No dealing,
   no shuffler, no randomness — just a scene. If we want a
   real dealer later, we port it after the visual shape is
   settled.
2. **A `view` function that renders it.** Cards drawn at their
   board positions, each stack cascading horizontally per the
   existing `stackWidth` math. Value + suit glyph per card.
   No hover, no drag handles, no animation — still image.
3. **`Main.elm` that wires it together** via `Browser.element`
   with an empty `Msg` type. The board is static; no updates
   yet.
4. **An `index.html` + `elm.js` build** served from
   `elm-port-docs/` via `python3 -m http.server 8788`.

Small scope, maybe 150 Elm LOC total across the three files.
The goal is visible pixels, not functionality. Once the board
renders correctly, we have a surface to iterate on: card
styling, layout, colors, the hand zone, the visual language
before drag interaction arrives.

### What I'll defer inside this checkpoint

- Hand cards (the player's held cards) — they belong on screen
  eventually but aren't needed for "does the board render?"
- Turn chrome, score display, next-turn button — post-MVP.
- Any CSS polish beyond "cards look like cards" — we'll tune
  together once pixels exist.
- The dealer (use a frozen hardcoded board).

## How you help

Start the dev server, open the page, look at the board.

Specifically:

- Do the cards read cleanly? Right value, right suit?
- Is stack cascade spacing right?
- Do board positions feel plausible, or are stacks stacking
  on top of each other / off the edge?
- Anything visually surprising — fonts, colors, sizes — that
  would have been cheaper to catch at this stage than later?

Gut-reaction tier only at this step. I don't need measurements
or decisions; I need "does this look like the start of LynRummy
or does it look wrong." The pattern is familiar — same lab-rat
posture we used on the VM simulator iterations.

I'll flag when the rendered page is ready; you look, you
react, we iterate. No budget pressure, no right answer yet.
It's the first step of a build-up pass — we're establishing
the visual floor for the later interaction work.

— C.
