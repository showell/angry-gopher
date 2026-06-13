// =============================================================================
// scenery — the shared rendering vocabulary for the world's drawable objects.
// A Scenery is anything placed in the scene and drawn back-to-front: it knows its
// depth (forward, from the Rider) and how to draw itself at two levels of detail.
//
// The COLLECTOR (view.ts, walking the road segments) builds these; the RENDERER
// (main.ts, which knows the camera) owns the near/far POLICY and calls the matching
// method. That split is the point: a collector deep in a recursive walk needn't know
// how close an object will end up — it returns both behaviours and lets the renderer
// choose. Objects with no up-close detail just point drawAsNear at the same code as
// drawAsFar. The interface is expected to grow (more LOD tiers, etc.) as needed.
// =============================================================================

// A ground-plane point in the RIDER's frame: how far to the right and forward of
// the Rider it sits. The fundamental coordinate of the whole rider-relative scene;
// shared by view.ts (which produces them) and intersection.ts (its pavement).
export interface RiderPt { right: number; forward: number }

// A flat ground-plane polygon — the road surface. Drawn before scenery, no LOD.
// Produced by view.ts (segment strips) and intersection.ts (corner + approach pavement).
export interface Quad { pts: RiderPt[]; color: string }

// A RAISED flat-shaded polygon (e.g. a guard-rail band or post): rider-frame corners that
// each carry a height off the ground. Near-plane clipped and projected like the road quads,
// but drawn after them so it stands above the pavement.
export interface Poly3 { pts: { right: number; forward: number; height: number }[]; color: string }

// the road surface colour, shared by the segment strips and the intersection pavement.
export const ROAD = '#34353c';

// A ground-plane point (right, forward) at a height, projected to the screen.
export type Project = (right: number, forward: number, height: number) => { x: number; y: number };
export type Ctx = CanvasRenderingContext2D;

export interface Scenery {
  forward: number;                               // depth from the Rider: sort key AND near/far choice
  height: number;                                // world height (m) — lets the renderer size-cull far, short objects
  drawAsNear(ctx: Ctx, project: Project): void;
  drawAsFar(ctx: Ctx, project: Project): void;
}

// Within this distance (metres) a Scenery is drawn with its near (detailed) variant. Pushed out from 40
// because the up-front trees look so good that the first cheap one beyond the threshold read as an obvious
// LOD seam; 70 keeps the near few tree rows detailed and only drops to the cheap variant well into the distance.
export const DETAIL_DIST = 70;

// The camera's near plane (metres in front of the eye). Anything closer must be clipped
// before projecting, or the divide-by-forward blows the point across the screen. Shared by
// the renderer (road quads + guard rails) and any Scenery that does its own 3D clip (towers).
export const NEAR = 0.4;

// Clip a rider-frame polygon (each vertex carrying a height off the ground) against the NEAR plane, so
// no vertex sits behind the eye where the perspective divide would fling it across the screen. Returns
// the clipped vertices (possibly fewer than 3 — the caller skips those). Shared by the road quads
// (main.ts) and the guard rails (guard_rail.ts).
export function clipNear(verts: { right: number; forward: number; height: number }[]): { right: number; forward: number; height: number }[] {
  const out: { right: number; forward: number; height: number }[] = [];
  for (let i = 0; i < verts.length; i++) {
    const a = verts[i], b = verts[(i + 1) % verts.length];
    const aIn = a.forward >= NEAR, bIn = b.forward >= NEAR;
    if (aIn) out.push(a);
    if (aIn !== bIn) {
      const f = (NEAR - a.forward) / (b.forward - a.forward);
      out.push({
        right: a.right + f * (b.right - a.right),
        forward: NEAR,
        height: a.height + f * (b.height - a.height),
      });
    }
  }
  return out;
}

// ---- ground curvature (experiment) ----
// The local ground is a spherical plateau of radius GROUND_RADIUS: it drops d^2/(2R) below the
// Rider's tangent plane at horizontal distance d. The renderer lowers each ground-quad vertex by
// this, so the road bends down toward a finite horizon (at ~sqrt(2R*EYE_H), ~490m here) instead
// of a vanishing point at infinity. Towers carry their own, stronger radius. Larger R = gentler.
export const GROUND_RADIUS = 100000;
export function groundDrop(right: number, forward: number): number {
  return (right * right + forward * forward) / (2 * GROUND_RADIUS);
}
