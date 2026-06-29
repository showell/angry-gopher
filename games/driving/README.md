# Safari Screensaver

**Welcome to the Safari!** Open [lynrummy.com/driving](https://lynrummy.com/driving),
press **SPACE**, and settle in: you're on a motorcycle at dusk, riding a winding
road through ~20 segments — past grazing cows and the odd giraffe, under radio
towers, chasing a blue truck into the sunset. You don't steer; the rider steers
*itself*, and watching it lean into each turn is the whole point. Tap **↑/↓** to
step the ride forward or back a frame at a time, or **D** for the debug overlay.
There's no goal and no clock — it's a 3D glorified screensaver.

It's pure, well-organized **TypeScript**, esbuilt to `app.js` and `@embedFile`d
into the zig binary, served public at `/driving` — `main.ts` builds its own
canvas/DOM, with no server logic and no user data.

**Status: parked.** It's a toy — journey over destination. The code is small,
entirely Claude-written, and every module opens with a top-of-file comment, so
**the code is the authority** for how anything works. This file is the canonical
home for the design *intent* the code can't tell you and the durable lessons from
building it (the project's memory notes now just point here).

**A sibling worth knowing: [Seattle Delivery](../../delivery/README.md).** The two
toys are cut from the same cloth — pure client-side TypeScript, a `<canvas>` the
client builds itself, a JS bundle the zig server merely embeds and serves, fully
deterministic, no server logic. Same stack, same "flipbook + algorithm" paradigm;
the difference is *which* hard problem sits at the center. Safari's is
**perception** — the cheapest lie the eye will accept (faked curvature, a ramped
dusk, a cat that's a flipbook of poses). Delivery's is **combinatorial cost** —
routing trucks to minimize an honest number. Same spirit, different hard part.

## Running & testing

`ops/start`, then open `/driving`. Gate: `node test/test_model.ts` (drives the
real model through the full route — continuity, no-loop, and the authored
invariants below) plus `npm run typecheck`. Deploy rides `ops/deploy` (sign-off
only).

**Dev hotkeys** (`main.ts`): ↑/↓ step, SPACE auto, **D** toggles the debug
overlay+HUD (default OFF — prod is clean). **S/H/J** fast-forward the *real* drive
(no teleport) to dusk / to seg16 / one intersection at a time — these made
testing late-route and dusk features far faster.

## The one durable architecture idea: rider-relative, no global coordinates

Position is always **relative to the current road segment** (`segment, along,
across, yaw, v`). There is deliberately **no global-world position system** —
`view.ts` composes per-segment transforms so everything is expressed *from the
rider*. The single sanctioned absolute is orientation relative to north
(`riderHeading`), used only for far scenery (a thing at infinity depends on
facing, not place). The road is a **graph** (intersection nodes, segment edges).
If global coordinates ever arrive, they go only on intersections as *sparse*
local relations between adjacent nodes ("Cambridge is across the river from
Boston") — never a dense grid. Keep this separation; it's the north star.

Modules are **noun-based**: one game-noun per file, owning that thing's behavior
end-to-end (this is the find-the-structure doctrine applied here). `main.ts` is
canvas/DOM/camera/input/HUD/loop *only* — never a kitchen sink. When code
accretes in `main.ts`, push it to the owning noun.

## Look doctrines (the non-obvious part)

- **Impressionist, not a simulator — "the cheapest lie the eye accepts."** Render
  the *felt* experience and pick the laziest math that produces it. Visible warped
  geometry and compressed time are accepted when they read convincingly; when two
  cheats disagree at a seam, choose the seam on purpose.
- **Keep effects subtle.** Stronger versions have been reverted repeatedly. Default
  gentle; don't re-crank an effect without being asked.
- **No fake symmetry.** Left-exit and right-exit geometry are two independent
  first-principles branches, not a `sign`-multiplier threaded down the stack
  (right is usually the harder branch). Don't "clean it up" into a mirror trick.
- **An intersection is a place, not just a junction** — it owns everything
  physically at the corner (pavement, approach stub, corner creatures, guard rail)
  and emits them as scene contributions. It keeps absorbing the joint over time.
- **Motifs + surprises.** A deliberately boring baseline (green trees, cows every
  segment, towers at every corner, gradual darkening) that rare departures
  violate. Hazards/scenery are kept **sparse so they actually startle** — scarcity
  is the feature. A feature debuts once, then reappears irregularly. Protect the
  boring segments; don't spread a new feature onto every segment "for consistency."
- **View-only overlays decouple gaze/camera from physics.** Some rider-state
  fields are pure view state that never touch motion, applied as camera transforms
  at render (lean → camera roll + focal pull-in; distraction → a slow head-turn).
  Any eventual "settled" feel likely belongs here, not in the motion.

## Curvature & sunset are perceptual cheats

The local ground is the top of a huge sphere dropping `d²/2R`, bending toward a
finite horizon, while the greater world (mountains, sun) sits on a flat plane with
the true horizon at eye level. A deliberate slight warp — ground curves,
infinite-horizon mountains don't; the seam is reconciled on purpose. Towers use a
stronger radius than the ground.

Time and the sunset are **pure functions of the step** (history index), so they
freeze on pause and run backwards on reverse — no wall-clock state. The route
stages the sunset on two authored sun-ward stretches; the sun sets behind the
west range; dusk is deliberately faster than real human time but ramped (squared)
slow enough to convince. Rock mountains always stay darker than the snowcap. These
are locked in `test_model`.

## The turning model: decision / physics split

A clean boundary Claude and Steve care about. `bike_physics.ts` owns the dumb
physics — a `RiderPhysics` state and `simulateRiderStep`, one frame of
integration applying the tilt-step lean-first (the only genuine physical constant
is `YAW_PER_TILT`). `decide()` in `rider.ts` is the rider's **pure brain**: it
returns only `{tiltStep, accel}` and must not call physics. The **same**
`simulateRiderStep` runs both the real move and the rider's imagined projections,
so an imagined path can never disagree with what actually happens — and anything
that's neither a decision nor a consequence (the old yaw-snap that teleported
heading) has no home and gets exposed.

The lean is chosen by **binary search** over a held-tilt path simulation. The lean
landscape is monotonic (sweep left→right: off-left → on-road band → off-right), so
"should the lean be further right?" flips exactly once, and a binary search on that
flip finds the on-road lean whose projected path ends closest to a target in ~12
probes. The target is an **asymptotic glide** (a fraction of the current offset —
ease toward centre, don't yank and overshoot) with a hold-band near centre to kill
twitch; on-road always beats off-road. The debug overlay draws the *actual* probe
arcs (red/green/blue, chosen lean yellow) — every dot a real probe, so the picture
can't lie about the algorithm.

**Snaps are off and the wobble is honest.** Both snaps (tilt→0, yaw→aim) were
deleted to get the clean break; the residual wobble is genuine physics (any held
lean curves a hair) and a glassy line reads dead. `YAW_PER_TILT` is small on
purpose so turns demand a deep, dramatic lean (~16° max) — Steve wants
slightly-timid corners that don't whip by, so there's time to see the animals.

## The chased truck

`truck.ts` — a dark-blue cab+trailer the rider pursues the whole route but never
catches. Brake lights glow only while it's actually slowing; headlight *cones*
(soft wedges, never lamps) switch on once the sun is behind the range and read
mainly in profile around corners. Unlike the cat (a pure function of rider state)
the truck carries its own per-frame `TruckState`, advanced one step per rider
frame with a parallel history so it scrubs cleanly on pause/reverse.

**The whole spec is three rules** (Steve was emphatic): (1) brake before turns,
(2) accelerate when behind schedule, (3) cruise when ahead. The schedule lerps the
expected lead from a start value down to a non-zero finish lead; "behind" reads the
rider's *distance*. **The truck's speed is never a function of the rider's speed**
— that coupling is banned (it was a v1 remnant). Its corner habits mirror the
rider's (same stopping distance, same angle-dependent turn speeds, just scaled
down) with one edge: a slightly quicker straight-line accel, capped. The lead is
*allowed* to exceed the start value (it peaks on the long straight) — pinning it to
a fixed ceiling would require matching the rider's speed, which contradicts rule-by-
rule independence.

## The crossing cat — a flipbook, not a sim

The cat (`cat_anatomy.ts` = shapes, `cat_motion.ts` = the crossing) crosses at a
few authored segments. Every frame just **picks one pose** as a function of the
rider's step — no physics, almost no interpolation: enter (leg trot) → frozen
(deer-in-headlights frontal stare) → leap (coil → flight → flight → land →
collapse-to-ground). Only the trajectory (vertical hop + lateral position) is
continuous. **Discrete beats blended** — don't do fraction math to compute "percent
coiled," just make the stills look right. Gotcha: each beat must own a *whole* step
(the rider's step advances ~1/frame, so a fractional coil window gets skipped).
As a cat crosses, the rider's focus tightens (view-only focal pull-in, peaking at
the landing) so the land→collapse reads large on screen.

## A tool worth keeping: Claude can see the canvas

`ops/snap_cat` → `snap_cat.ts` → `mini_canvas.ts` is a **dependency-free software
rasterizer** that runs the *real* cat drawing code and writes a PNG contact sheet
Claude can `Read` — so Claude self-evaluates the rendered stills instead of
round-tripping every visual judgment through Steve. It implements only the Canvas2D
subset the cat needs (transform stack, paths, fill/stroke, supersample AA); the
isolated cat, not the full scene, is the right scope. PNG via `node:zlib`, no deps.
This is the model for homegrown instruments here.

## Known open work

- **Camera pitch.** `project()` does yaw and roll but no pitch — needed to "look up
  under the canopy." The known missing piece.
- Intersections keep absorbing the joint (corner creatures conceptually owned by
  the node); generalize "landmarks owned by a graph element" beyond towers.
- Residual rider slowness (far-shoulder phantom braking in the held-tilt
  projection, fudged by a brake-decay constant).
