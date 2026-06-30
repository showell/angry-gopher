# Safari Screensaver

> ## ⚠️ DEPRECATED — the TypeScript source in this directory
>
> The live `/driving` is the **Zig→WASM** implementation in **[`wasm/`](wasm/)**
> (`*.zig` + `blitter.js`). The `.ts` files here (`main.ts` and friends) are **no
> longer built or served** — they survive only as the historical **port reference**
> (a few `wasm/*.zig` comments still cite them by name). **New work goes in
> [`wasm/`](wasm/).** Everything below describes design *intent* shared by both.

**Welcome to the Safari!** Open [lynrummy.com/driving](https://lynrummy.com/driving),
press **SPACE**, and settle in: you're on a motorcycle at dusk, riding a winding
road through ~20 segments — past grazing cows and the odd giraffe, under radio
towers, chasing a blue truck into the sunset. You don't steer; the rider steers
*itself*, and watching it lean into each turn is the whole point. Tap **↑/↓** to
step the ride forward or back a frame at a time, or **J** to jump to the next
intersection. There's no goal and no clock — it's a 3D glorified screensaver.

It's a **Zig core compiled to WebAssembly** plus a tiny hand-written **JS
blitter**: the zig (`games/driving/wasm/*.zig`) computes all the geometry and the
perspective projection and writes a flat draw-command buffer into linear memory;
`blitter.js` just fills the polygons it emits — its own canvas/DOM, no server
logic, no user data. Built by `ops/build_safari_wasm` → `safari.wasm`,
`@embedFile`d into the zig binary, served public at `/driving`. It was **ported
from an original pure-TypeScript implementation** (`main.ts` and friends), kept in
this directory as the port reference — see `HISTORY.md`.

**Status: the zig→WASM port is the live version**, with a short cleanup tail (see
*Known open work*); in ambition it's parked — a toy, journey over destination. The
code is small, entirely Claude-written, and every module opens with a top-of-file
comment, so **the code is the authority** for how anything works. This file is the
canonical home for the design *intent* the code can't tell you and the durable
lessons from building it (the project's memory notes now just point here).

**Where the code lives.** The canonical implementation is the zig modules in
[`wasm/`](wasm/) (`*.zig`) plus `wasm/blitter.js`. The original TypeScript
(`main.ts` and the `*.ts` modules beside it) is kept as the **port reference**: the
ports are faithful and noun-for-noun, so a `.ts` named below almost always has a
`.zig` twin of the same name (`rider.ts` → `wasm/rider.zig`, `truck.ts` →
`wasm/truck.zig`, …). The design intent in the sections below is shared by both;
where the two genuinely diverge it's called out.

**A sibling worth knowing: [Seattle Delivery](../../delivery/README.md).** The two
toys are cut from the same cloth *in spirit* — a `<canvas>` the client builds
itself, an asset the zig server merely embeds and serves, fully deterministic, no
server logic, the same "flipbook + algorithm" paradigm. They no longer share a
*stack*, though: Delivery is pure client-side TypeScript, while Safari's camera now
runs as a Zig→WASM core feeding a JS blitter. The deeper difference is *which* hard
problem sits at the center. Safari's is **perception** — the cheapest lie the eye
will accept (faked curvature, a ramped dusk, a cat that's a flipbook of poses).
Delivery's is **combinatorial cost** — routing trucks to minimize an honest number.
Same spirit, different hard part, now a different stack.

For why the engine and the math were never the hard part — and what it means to
build something whose only spec is a perception in someone's head — read the essay
[**"You Can't Freeze a Sunset"**](https://lynrummy.com/blog/you-cant-freeze-a-sunset).

## Running & testing

`ops/start` builds the wasm (`ops/build_safari_wasm`) and launches the server;
open `/driving`. Deploy rides `ops/deploy` (sign-off only). The original
TypeScript reference still has its own gate — `node test/test_model.ts` (drives the
real TS model through the full route — continuity, no-loop, the authored invariants
below) plus `npm run typecheck` — useful for checking the port against the source.

**Dev hotkeys** (`wasm/blitter.js`): ↑/↓ step, SPACE auto, **J** fast-forwards the
*real* drive (no teleport) one intersection at a time, **D** toggles the dev overlay
(the frame-budget HUD + step/seg + buffer peak) — **off by default** so prod is
clean, with a dim `D` affordance left on-screen so it stays discoverable.

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
end-to-end (this is the find-the-structure doctrine applied here). The host glue is
kept *out* of the nouns: in the zig build, `wasm/blitter.js` owns
canvas/DOM/input/HUD and `wasm/safari.zig` is the one JS-visible module (the step
clock + the exported `advance`/`back`/`renderFrame`), while `render.zig` is the
scene orchestrator — none of them a kitchen sink. (In the TS reference that glue
all lived in `main.ts`.) When code accretes in the host layer, push it to the
owning noun.

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
twitch; on-road always beats off-road. (In the TS build a debug overlay drew the
*actual* probe arcs — red/green/blue, chosen lean yellow, every dot a real probe —
so the picture couldn't lie about the algorithm; the zig dev overlay shows
frame-budget stats instead.)

**Snaps are off and the wobble is honest.** Both snaps (tilt→0, yaw→aim) were
deleted to get the clean break; the residual wobble is genuine physics (any held
lean curves a hair) and a glassy line reads dead. `YAW_PER_TILT` is small on
purpose so turns demand a deep, dramatic lean (~20° max) — Steve wants
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

The cat crosses at a few authored segments. Every frame just **picks one pose** as
a function of the rider's step — no physics, almost no interpolation: enter (leg
trot) → frozen
(deer-in-headlights frontal stare) → leap (coil → flight → flight → land →
collapse-to-ground). Only the trajectory (vertical hop + lateral position) is
continuous. **Discrete beats blended** — don't do fraction math to compute "percent
coiled," just make the stills look right. Gotcha: each beat must own a *whole* step
(the rider's step advances ~1/frame, so a fractional coil window gets skipped).
As a cat crosses, the rider's focus tightens (view-only focal pull-in, peaking at
the landing) so the land→collapse reads large on screen.

In the zig build the cat is a **baked flipbook**: `ops/bake_cat` runs the *real*
TS `cat_anatomy.ts` drawing code through a `PolyRecorder` shim (a fake Canvas that
captures each `fill()` as a polygon and each `stroke()` as one ribbon polygon) and
writes the poses out as `wasm/cat_frames.zig`; `wasm/cat.zig` just draws the right
still each step. So the polygon-only wasm seam can't draw curves, yet the on-screen
cat is the genuine TS anatomy, frozen — not a hand-redrawn approximation.

## A tool worth keeping: Claude can see the canvas

The recurring instrument here: **run the REAL drawing code and let Claude `Read`
the result**, so Claude self-evaluates rendered stills instead of round-tripping
every visual judgment through Steve. Two incarnations: `ops/bake_cat`'s
`PolyRecorder` (above) captures the cat as polygons for the wasm; the TS-era
`ops/snap_cat` → `snap_cat.ts` → `mini_canvas.ts` is a **dependency-free software
rasterizer** (the Canvas2D subset the cat needs — transform stack, paths,
fill/stroke, supersample AA; PNG via `node:zlib`, no deps) that wrote a PNG contact
sheet of the isolated cat. Both are the model for homegrown instruments here.

## Known open work

- Intersections keep absorbing the joint (corner creatures conceptually owned by
  the node); generalize "landmarks owned by a graph element" beyond towers.
- Residual rider slowness (far-shoulder phantom braking in the held-tilt
  projection, fudged by a brake-decay constant).
