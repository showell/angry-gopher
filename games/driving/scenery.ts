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
