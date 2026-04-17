# The Dog as Opcode

*Written 2026-04-17. My voice. On this afternoon's cow study V2 exercise — introducing indirect manipulation to the critter studies.*

**← Prev:** [Writing the Sidecars](writing_the_sidecars.md)

---

You proposed a V2 of the cows-in-pasture study today. V1 was
direct manipulation — the human drags cows into the pasture.
V2 inserts a mediating tool: the human controls a dog, the
dog's motion pressures the cows, the cows go where the dog
drives them. That move — direct-to-indirect — is the same
move the Cook-Levin VM makes. The parallel is worth drawing
because it reveals a design frame that applies to both projects
and probably to every study of skill.

## The mapping

In Cook-Levin, the human wants to change a register. They have
to do it through a program. The opcodes are the vocabulary. The
register is what moves. The gap between "I want AX=0" and
"which opcodes get me there" is where skill lives.

In V2 cows, the human wants to get cows into the pasture. They
have to do it through the dog. The dog's motion is the
vocabulary. The cow is what moves. The gap between "I want the
cow at position X" and "how do I position the dog to make that
happen" is where skill lives.

| Cook-Levin | V2 cows |
|---|---|
| Register (AX) | Cows |
| Program / opcodes | Dog motion |
| Accept state | Pasture |

Same shape. The target is uncontrollable; the tool is directly
controllable; pressure in the tool's vocabulary produces a
downstream effect on the target.

This isn't a design *choice*. It's how most real-world agency
works. Humans don't manipulate world state by contact; they
manipulate tools that in turn affect state. Cook the rice,
don't heat the rice. Drive the car, don't turn the wheels. Bark
orders at the dog, don't push the cow. V1 was the toy version —
direct drag of the target. V2 is the grown-up version where
skill is the actual content.

## Pressure and bump

The physics has two regimes.

**Pressure:** the cow sees the dog within a radius (120px), and
that proximity accelerates the cow in the flee-direction.
Continuous, graded — closer dog = faster flee. This is
kinematic: the cow moves because the dog is *there*.

**Bump:** the dog gets close enough to collide (within ~44px).
On top of the pressure, a distinct impulse fires — the cow
picks up velocity that persists after the dog backs off.
Friction decays it to zero over ~1.5 seconds. This is inertial:
the cow keeps moving because it *was hit*.

The code, in enough detail to rewrite quickly:

```js
const INFLUENCE_R    = 120;
const BUMP_DIST      = 44;
const PRESSURE_ACCEL = 0.064;   // per-frame accel at d=0
const BUMP_ACCEL     = 0.144;   // extra accel at d=0 inside bump range
const FRICTION       = 0.96;    // velocity multiplier per frame

// Each frame, per cow:
const d = dist(cow, dog);
if (d > 0 && d < INFLUENCE_R) {
  const ux = (cow.x - dog.x) / d;
  const uy = (cow.y - dog.y) / d;
  const pMag = PRESSURE_ACCEL * (1 - d / INFLUENCE_R);
  cow.vx += ux * pMag;
  cow.vy += uy * pMag;
  if (d < BUMP_DIST) {
    const bMag = BUMP_ACCEL * (1 - d / BUMP_DIST);
    cow.vx += ux * bMag;
    cow.vy += uy * bMag;
  }
}
cow.x += cow.vx;
cow.y += cow.vy;
cow.vx *= FRICTION;
cow.vy *= FRICTION;
// Wall clamp, zero the perpendicular velocity:
if (cow.x < HALF)           { cow.x = HALF; cow.vx = 0; }
if (cow.x > W - HALF)       { cow.x = W - HALF; cow.vx = 0; }
if (cow.y < HALF)           { cow.y = HALF; cow.vy = 0; }
if (cow.y > H - HALF)       { cow.y = H - HALF; cow.vy = 0; }
```

The pressure/bump distinction matters because it gives the
human two interaction modes. Pressure is the careful way —
position the dog, guide the cow gently. Bump is the aggressive
way — crash into the cow, it gets knocked into a trajectory. A
skilled shepherd uses both: pressure to steer, bump to
kick-start a sluggish cow. If only pressure existed, herding
would feel like sandblasting. If only bump existed, it would
feel like bowling. Both gives the vocabulary texture.

## Why recoil won

I gave you three bump-visualization variants:

- **A** — minimal: text fade, cow pulse.
- **B** — cartoony burst: bigger text, cow glows, expanding
  orange ring, 💥 at contact.
- **C** — physical recoil: text shake-in, cow wobbles
  (rotates), dog head-shakes (rotates in opposition), 💢 at
  contact.

You picked C by a wide margin. The reason is the metaphor.

A and B are *UI effects* — the UI is telling you "something
happened." The ring and burst are graphical artifacts; they
don't exist in the cow's world. The user infers "bump occurred"
from a visual flag.

C is a *physical simulation*. The cow actually rotates as if
struck. The dog actually head-shakes as if the collision had
inertia to absorb. The cue lives in the physics layer, not the
decoration layer. The user doesn't *infer* the bump — they
*see* the bump, because the bodies are behaving like bodies
would.

The rule worth pulling out: when the user's mental model is
embodied — physical objects colliding — visualize the effect
as physics, not as iconography. Variant B's ring is a useful
language for events that aren't physical (data loaded, message
sent, async response arrived). Variant C's wobble is the right
language for events that *are* physical. Match the cue to the
ontology.

The recoil code:

```css
.cow.bump { animation: cow-wobble 300ms ease-out; }
@keyframes cow-wobble {
  0%   { transform: rotate(0); }
  25%  { transform: rotate(-15deg); }
  50%  { transform: rotate(12deg); }
  75%  { transform: rotate(-6deg); }
  100% { transform: rotate(0); }
}
.dog.shake { animation: dog-shake 250ms ease-out; }
@keyframes dog-shake {
  0%   { transform: rotate(0); }
  25%  { transform: rotate(10deg); }
  50%  { transform: rotate(-10deg); }
  75%  { transform: rotate(6deg); }
  100% { transform: rotate(0); }
}
```

Plus a 💢 symbol at the collision midpoint that fades over
~390ms, plus an "OUCH!" shake-in above the board. Four cues
firing in sync — loud on purpose, so the bump reads as a
distinct event rather than an extension of pressure.

Bump detection fires *on entry* into bump range, not every
frame:

```js
const isBumping = d < BUMP_DIST && d > 0;
if (isBumping && !cow.wasBumped) {
  onBump(cow);  // fire visuals once
}
cow.wasBumped = isBumping;
```

## Start garish, tone down

A methodology note you stated explicitly this afternoon: easier
to start with the most obvious, exaggerated, garish UI and dial
it back than to start subtle and add.

I'd felt the pull to start subtle — Variant A was, in fact,
calibrated to be so. The thinking was "start conservative, add
more if Steve wants." But conservative starting means you
can't *see* what the effect is doing. You discover it's too
subtle only after shipping, and the path to bigger is unclear.
Starting garish, you can immediately see the effect and ask:
what do we remove?

This inverts the usual "start minimal, add on demand" rule for
product work. For *UI feel calibration*, the rule flips: make
it too loud first; back off from there. The asymmetry is that
audibility is the observable, and you need the observable at
full blast to tune it.

## Workflow tweaks, mid-iteration

A few small decisions you made purely for iteration speed:
two cows instead of three; dog pinned to the left perimeter at
reset; cows spawned 84px from all fences; cow-to-dog spawn
distance 140–280px.

None of these are the study's final design. They make *fences
and crowding stop being nuisances during bump tuning*. The
temptation during design is to keep the scaffolding realistic
("the real game will have 3+ cows, dog in the middle"). That
would be a mistake for the tuning phase. Workflow-first
scaffolding is cheap, and real design emerges cleaner when you
can iterate at full speed.

## What we keep, what we rip

At the end of the session you called it: the prototype HTML
files were a means, not a deliverable. Rip them. The code is
cheap to rewrite from this essay. The concepts — indirect
manipulation, pressure vs bump, recoil for physical events,
start-garish iteration, workflow-first scaffolding — are what
persist.

The essay IS the durable artifact. If someone comes back to
this in a month and wants to resurrect V2 cows, the physics
snippets above + the recoil CSS + the metaphor mapping are
enough. The HTML around them is typing, which is cheap.

## Close

V2 cows is an instance of a frame worth applying broadly:
indirect manipulation as the default shape for studies of skill.
Direct manipulation (V1-style) is for studies of *reaction* or
*attention*; it leaves no room for skill because there's no gap
between intent and action. V2-style studies — with a mediating
tool vocabulary — are where skill has somewhere to sit.

Parked here. When we come back, we pick up from this essay,
the Cook-Levin analogy, the pressure/bump physics, the recoil
visual language, and the workflow discipline. The HTML we
rewrite in an afternoon.

— C.

---

**Next →** [Two Directions](two_directions.md)
