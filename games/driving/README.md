# Safari Screensaver

Open [lynrummy.com/driving](https://lynrummy.com/driving), press **SPACE** and
settle in. You ride a motorcycle at dusk down a winding road, past grazing
cows and the odd giraffe, under radio towers, chasing a blue truck into the
sunset. The rider steers itself; watching it lean into each turn is the
point. **↑/↓** step the ride a frame at a time and **J** jumps to the next
intersection. It is a 3D screensaver: just the road.

## The code

The live ride is a **Zig core compiled to WebAssembly** in [`wasm/`](wasm/),
plus a small **JS blitter**, `wasm/blitter.js`. The Zig computes the geometry
and the perspective projection and writes a flat buffer of draw commands into
linear memory; the blitter fills the polygons. `ops/build_safari_wasm` builds
`safari.wasm`, which the zig server embeds and serves at `/driving`. Every
module opens with a comment saying what it does: read the code.

The `.ts` files in this folder (`main.ts` and the modules beside it) are the
original TypeScript ride, kept as the **port reference**. The port is noun
for noun, so `rider.ts` has its twin in `wasm/rider.zig`, `truck.ts` in
`wasm/truck.zig`. New work goes in `wasm/`. The design below holds for both.

The same ride runs as a native desktop screensaver, a Linux X11 window and a
Windows `.scr`, with a software rasterizer in place of the blitter:
[`native/README.md`](native/README.md).

[Seattle Delivery](../../delivery/README.md) is its sibling. Both are
deterministic canvas toys with a Zig core. Safari's hard problem is
perception, so its UI is nearly all Zig; Delivery's is combinatorial cost,
so only its solver is.

## Running and testing

`ops/start` builds the wasm and starts the server; open `/driving`.
`ops/check_safari` (part of `ops/check`) drives `safari.wasm` over the whole
course and checks the critter culls and the draw buffer. The TypeScript
reference keeps its own tests, `node test/test_model.ts` (continuity, the
loop check, the authored invariants below) and `npm run typecheck`, for
checking the port against it.

**Dev keys** (`wasm/blitter.js`): ↑/↓ step, SPACE plays, **J** drives on to
the next intersection, **D** toggles the dev overlay (the frame-budget HUD,
step and segment, buffer peak). The overlay starts off; the hint at the foot
of the page names the key.

## Rider-relative coordinates

Position is always **relative to the current road segment** (`segment, along,
across, yaw, v`). Everything is expressed from the rider: per-segment
transforms compose the view. The one absolute is the rider's heading against
north, used for far scenery, since a thing at infinity
depends on facing alone. The road is a **graph** of intersections and
segments. Global coordinates, if they come, belong on intersections as sparse
relations between neighbours ("Cambridge is across the river from Boston"),
never as a dense grid.

**Modules are nouns:** one game noun a file, owning its behaviour. The host
glue stays apart: `wasm/blitter.js` owns the canvas, DOM, input and HUD;
`wasm/safari.zig` is the one module JS sees (the step clock, `advance`,
`back`, `renderFrame`); `wasm/render.zig` orchestrates the scene. Code that
gathers in the host layer moves to its noun.

## How it looks

- **Impressionist: the cheapest lie the eye accepts.** Render the felt
  experience with the laziest math that produces it. Warped geometry and
  compressed time are fine when they convince; where two cheats meet, place
  the seam on purpose.
- **Effects stay subtle.** Stronger versions were tried and reverted. Keep an
  effect gentle; turn one up when asked.
- **Left and right are separate.** Left-exit and right-exit geometry are two
  branches, each from first principles, with right usually the harder. Keep
  them apart; a mirror trick is wrong here.
- **An intersection is a place.** It owns everything at the corner
  (pavement, approach stub, corner creatures, guard rail) and emits it into
  the scene.
- **Motifs and surprises.** A steady baseline (green trees, cows every
  segment, towers at every corner, the slow dusk) sets up rare departures.
  Hazards and scenery stay **sparse so they startle**. A feature debuts once,
  then returns irregularly; the plain segments stay plain.
- **View-only state moves the camera, apart from the physics.** Lean becomes
  camera roll and a focal pull-in; distraction becomes a slow head-turn.

## Curvature and sunset are perceptual cheats

The local ground is the top of a huge sphere, dropping `d²/2R` toward a
finite horizon. The far world (mountains, sun) sits on a flat plane with the
true horizon at eye level. The ground curves and the mountains stay flat, and
the seam between them is reconciled on purpose. Towers use a tighter radius
than the ground.

Time and the sunset are **pure functions of the step**, so they freeze on
pause and run backwards on reverse. The route stages the sunset on two
sun-ward stretches, and the sun sets behind the west range. Dusk runs faster
than real time, ramped (squared) slowly enough to convince. Rock stays darker
than the snowcap. `test_model` holds these.

## The turning model: decision and physics

The physics is plain: `simulateRiderStep` integrates one frame, applying the
tilt step lean-first, and `YAW_PER_TILT` is its one physical constant.
`decide()` is the rider's **pure brain**: it returns `{tiltStep, accel}` and
leaves the physics alone. The **same** `simulateRiderStep` runs the real
move and the rider's imagined paths, so what the rider imagines is what
happens. Anything that is neither a decision nor its consequence stands out.
(All three are in `wasm/rider.zig`; the TS reference splits them across
`bike_physics.ts` and `rider.ts`.)

The lean is found by **binary search** over a held-tilt path. Sweeping the
lean from left to right goes off-road left, on-road, off-road right, so
"lean further right?" flips once, and about a dozen probes find the on-road
lean whose path ends nearest the target. The target is an **asymptotic
glide**, a fraction of the current offset, easing toward the centre, with a
hold band near the centre to stop twitching. On-road always beats off-road.

**The wobble is honest.** The snaps (tilt to zero, yaw to aim) are gone;
the slight wobble is real physics, since any held lean curves a hair, and a
glassy line looks dead. `YAW_PER_TILT` is small, so turns take a deep lean
(about 20° at most) and corners pass slowly enough to see the animals.

## The chased truck

`wasm/truck.zig` is a dark-blue cab and trailer the rider chases the whole
route, always a little ahead. Brake lights glow while it slows; headlight cones
(soft wedges) switch on once the sun is behind the range and show mainly in
profile around corners. The truck carries its own state, advanced one step
per rider frame with a parallel history, so it scrubs cleanly.

**Its whole spec is three rules:** brake before turns, accelerate when behind
schedule, cruise when ahead. The schedule eases the expected lead from a
start value down to a finish lead above zero, and "behind" reads the rider's
distance. **The truck's speed is independent of the rider's.** Its corner
habits mirror the rider's, scaled down, with a slightly quicker capped
acceleration on the straight. The lead may exceed its start value (it peaks
on the long straight); a fixed ceiling would tie the truck to the rider's
speed.

## The crossing cat: a flipbook

The cat crosses at a few authored segments. Each frame **picks one pose** by
the rider's step: enter (a trot), freeze (a frontal stare), leap (coil,
flight, flight, land, collapse). Only the path (the hop and the sideways
position) is continuous. **Discrete beats beat blending:** make each still
look right. Each beat must own a whole step, since the step advances about
one a frame and a fractional window gets skipped. As the cat crosses, the
rider's focus tightens, peaking at the landing.

The Zig draws a **baked flipbook**. `ops/bake_cat` runs the TS drawing code,
`cat_anatomy.ts`, through a `PolyRecorder` (a stand-in canvas that records
each `fill()` as a polygon and each `stroke()` as a ribbon) and writes the
poses to `wasm/cat_frames.zig`; `wasm/cat.zig` draws the right one each
step. The wasm draws polygons only, and the cat on screen is still the real
TS anatomy.

## Claude can see the canvas

The instrument worth copying: **run the real drawing code and let Claude
read the image**, so Claude judges rendered stills itself. `ops/bake_cat`'s
`PolyRecorder` is one. `ops/snap_cat` is the other: `snap_cat.ts` draws the
cat with `mini_canvas.ts`, a small software rasterizer (the Canvas2D subset
the cat needs, with PNG output through `node:zlib`), into a contact sheet.

## Open work

- Intersections take on more of the joint (corner creatures owned by the
  node); generalize "landmarks owned by a graph element" past towers.
- The rider still slows a little: far-shoulder phantom braking in the
  held-tilt projection, eased by a brake-decay constant.
