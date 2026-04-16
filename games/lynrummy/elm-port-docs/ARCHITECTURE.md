# elm-lynrummy architecture

Thin host shell + plugin-style gesture modules + shared
primitives. Designed so each new gesture (stack-merge, peel,
pluck, half-stack-grab) is a self-contained module that drops
into the existing harness without touching the others.

See also:
- `STUDY_RESULTS.md` — empirical findings from the gesture studies
- `~/showell_repos/angry-cat/src/lyn_rummy/UI_DESIGN.md` —
  declared design philosophy

## Module map

```
src/
  Main.elm                  -- host: dispatcher + study config
  Card.elm                  -- card/stack/suit types & helpers
  Layout.elm                -- geometry constants + card SVG
  Drag.elm                  -- physics: projection, hysteresis,
                            --   velocity smoothing, mouse decoding
  Study.elm                 -- trial counter, breaks, banner,
                            --   results tally
  Gesture/
    SingleCardDrop.elm      -- the first solidified gesture
```

## Plugin shape

Every gesture module exposes:

```elm
type State  -- opaque
type Msg    -- opaque
type alias Config = { ... }   -- per-trial host-provided params
type GestureOutcome = Pending | Completed { ok, durationMs, extra }

name : String
init : Config -> State
update : Msg -> State -> ( State, Cmd Msg, GestureOutcome )
subscriptions : State -> Sub Msg
view : State -> Html Msg
```

The host:
- holds an `ActiveGesture` sum type with one variant per
  registered gesture
- routes `Msg` to the active gesture
- watches for `Completed` outcomes
- on completion, records the trial with `Study`, fires the
  `logTrial` port, and re-initializes the gesture for the next
  trial (or enters break / completion)

## Adding a new gesture

1. Create `src/Gesture/MyGesture.elm` matching the plugin shape.
2. Add a variant to `Main.ActiveGesture`.
3. Add wrapper cases to `Main.update`, `Main.view`,
   `Main.subscriptions`.
4. Add a `MyGestureMsg` variant to `Main.Msg`.
5. (Optional) Replace the demo `studyConfig` to drive the new
   gesture's experiment.

The compiler will catch any case branch you forget — that's the
whole reason the sum type is preferred over a record-of-functions.

## Study harness conventions

- `breakEvery` trials are warmup and discarded from analysis.
- Conditions are named opaquely (e.g. "A", "B", "1", "2") in
  blind studies so console logs can't leak the active condition.
- Per-trial JSON includes `trial`, `cond`, `ok`, `durationMs`,
  plus arbitrary `extra` fields supplied by the gesture.

## Known shipped defaults

Defined as constants in `Drag.elm` and `Gesture/SingleCardDrop.elm`.
See `STUDY_RESULTS.md` for provenance:
- lookahead 60 ms
- lock threshold 0.50, unlock 0.25 (hysteresis)
- ghost opacity 0.7
- velocity EMA α 0.30
