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

// Within this distance (metres) a Scenery is drawn with its near (detailed) variant.
export const DETAIL_DIST = 40;

// The camera's near plane (metres in front of the eye). Anything closer must be clipped
// before projecting, or the divide-by-forward blows the point across the screen. Shared by
// the renderer (road quads + guard rails) and any Scenery that does its own 3D clip (towers).
export const NEAR = 0.4;

// ---- ground curvature (experiment) ----
// The local ground is a spherical plateau of radius GROUND_RADIUS: it drops d^2/(2R) below the
// Rider's tangent plane at horizontal distance d. The renderer lowers each ground-quad vertex by
// this, so the road bends down toward a finite horizon (at ~sqrt(2R*EYE_H), ~490m here) instead
// of a vanishing point at infinity. Towers carry their own, stronger radius. Larger R = gentler.
export const GROUND_RADIUS = 100000;
export function groundDrop(right: number, forward: number): number {
  return (right * right + forward * forward) / (2 * GROUND_RADIUS);
}
