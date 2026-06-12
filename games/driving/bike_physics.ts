// bike_physics — the DUMB physics of the motorcycle, and nothing else. One step of integration: a lean
// rotates the heading, an acceleration changes the speed, and speed-along-heading moves the position. This is
// the SAME step both the world engine (getNextRiderState) and the rider's own projections (simulateRiderPath)
// use, so a decision can never disagree with what actually happens. Decision-making, road geometry, safety
// margins, the gaze — none of that is physics; it all lives in rider.ts. The one genuine physical constant
// here is YAW_PER_TILT (how hard a lean turns the bike); STRAIGHTEN_MARGIN and friends are the rider's world,
// not intrinsic facts, so they stay out.

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

// The purely PHYSICAL facts about the bike: its lean, heading, speed, and position. Everything else the rider
// carries (which segment, the gaze, decision read-outs) is layered on top in rider.ts's RiderState.
export interface RiderPhysics {
  tilt: number;    // the bike's lean (rad; + = leaned right) — what turns it
  yaw: number;     // heading offset from straight down the lane (rad; + = pointed right)
  v: number;       // speed along the path (m/press)
  along: number;   // progress along the current segment (m)
  across: number;  // lateral offset from the lane centre (m; + = right)
}

// ----------------------------------------------------------------------------
// constants — the only intrinsic physical fact
// ----------------------------------------------------------------------------

export const YAW_PER_TILT = 0.1;   // the lean's leverage: each unit of tilt yaws the heading this much per frame

// ----------------------------------------------------------------------------
// code
// ----------------------------------------------------------------------------

// Advance the bike ONE frame, applying the rider's two controls: a TILT-STEP (he works the lean over by a
// notch) and an ACCELERATION (throttle/brake). The rider LEANS FIRST — the tilt-step lands at the START of the
// frame — and then THAT lean induces this frame's heading change, so leaning and turning happen together (no
// one-frame lead). The acceleration changes the speed; the new speed along the average heading moves the
// position. Applying the tilt-step here is a slightly odd boundary, but it keeps the model clean: the RIDER
// decides to change his lean, and the physics is what makes that change — and the turn it causes — happen.
export function simulateRiderStep(phys: RiderPhysics, tiltStep: number, accel: number): RiderPhysics {
  const tilt = phys.tilt + tiltStep;                 // the rider leans FIRST (instantaneous tilt-step at the frame's start)
  const v = phys.v + accel;                          // acceleration induces the velocity change
  const headingChange = YAW_PER_TILT * tilt;         // the (now-leaned) tilt induces this frame's heading change
  const midHeading = phys.yaw + headingChange / 2;   // average heading over the frame
  return {
    tilt,
    yaw: phys.yaw + headingChange,
    v,
    along: phys.along + v * Math.cos(midHeading),     // velocity along the (mid) heading advances the position
    across: phys.across + v * Math.sin(midHeading),
  };
}
