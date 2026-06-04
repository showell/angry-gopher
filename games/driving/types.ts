// =============================================================================
// driving game — type vocabulary
// =============================================================================
//
// PHILOSOPHY (Steve, 2026-06-04)
//
// The World is always relative to the car. From the parking space, "the world"
// is the pavement ahead, the cars beside me, the buildings across the lot —
// nothing more. There is an underlying graph that connects the parking space to
// the lot to the small road to the big road to the highway to the country road
// and on and on, but for whatever segment or intersection I am on, only the
// nearby world matters.
//
// So the authoritative model is a RELATIONAL GRAPH of road segments joined by
// intersections. Everything is expressed in a segment's own LOCAL FRAME
// (distance along, offset across). The model holds NO absolute (x, z).
// Absolute world coordinates are a DERIVED concern of the 2D map view only —
// produced by walking the graph, never stored.
//
// Conventions used below:
//  - Author these directly in TypeScript (no separate DSL for now).
//  - Prefer UNION types + composition of small types. No subclassing.
//  - Cross-references are by branded id, so hand-authored literals stay acyclic.
// =============================================================================


// ----------------------------------------------------------------------------
// Units — branded scalars. "No fudging": you cannot add Meters to Seconds, and
// miles<->meters / mph<->m·s conversions go through explicit branded helpers.
// ----------------------------------------------------------------------------
type Brand<K extends string, T> = T & { readonly __brand: K };

// length
type Meters = Brand<'Meters', number>;
type Miles  = Brand<'Miles', number>;

// time
type Seconds = Brand<'Seconds', number>;
type Hours   = Brand<'Hours', number>;

// speed
type MetersPerSecond = Brand<'MetersPerSecond', number>;
type MilesPerHour    = Brand<'MilesPerHour', number>;

// acceleration
type MetersPerSecond2 = Brand<'MetersPerSecond2', number>;

// angle
type Radians = Brand<'Radians', number>;

// Conversions are signatures only here (implemented later). They are the ONLY
// sanctioned way to cross unit families — there is no implicit coercion.
declare function meters(n: number): Meters;
declare function miles(n: number): Miles;
declare function seconds(n: number): Seconds;
declare function hours(n: number): Hours;
declare function radians(n: number): Radians;

declare function milesToMeters(d: Miles): Meters;          // × 1609.344
declare function metersToMiles(d: Meters): Miles;
declare function hoursToSeconds(t: Hours): Seconds;        // × 3600
declare function mphToMps(v: MilesPerHour): MetersPerSecond;     // × 0.44704
declare function mpsToMph(v: MetersPerSecond): MilesPerHour;     // × 2.236936


// ----------------------------------------------------------------------------
// Geometry primitives
// ----------------------------------------------------------------------------
type Cardinal = 'N' | 'E' | 'S' | 'W';   // a road's travel direction
type Side     = 'left' | 'right';        // relative to travel
type Turn     = 'left' | 'right' | 'straight' | 'uturn';

// NOTE: Vec2 / Vec3 are NOT how the model stores position (that is segment-
// local — see SegmentPos / Placement). They appear only in DERIVED layout and
// in the 3D object-local model.
interface Vec2 { x: Meters; z: Meters }            // ground plane: +x east, +z north
interface Vec3 { x: Meters; y: Meters; z: Meters } // y = up
interface Rect { min: Vec2; max: Vec2 }            // axis-aligned


// ----------------------------------------------------------------------------
// Segment-local placement — the heart of "the world is relative to the car".
// A thing's position is given inside ONE road segment's frame.
// ----------------------------------------------------------------------------
interface SegmentPos {
  along: Meters;   // 0 at the segment's start (where you enter), grows toward its end
  across: Meters;  // signed lateral position from the centerline (+ = right of travel)
}

// Where an obstruction sits beside a segment. `offset` is measured OUTWARD from
// the pavement EDGE on that side, so it cannot be negative — an obstruction can
// never be on the pavement by construction. (This is necessary but NOT
// sufficient at corners — see the CORNER concept below.)
interface Placement {
  segment: SegmentId;
  side: Side;
  along: Meters;      // distance from the segment start
  offset: Meters;     // >= 0, from the pavement edge to the object's near face
  facing: Radians;    // which way the object faces (so a corner shows front vs side)
}

// 2D collision shape, axis-aligned to the segment it lives in.
interface Footprint { width: Meters; depth: Meters }

// 3D render model, in the object's OWN local frame (centered at its placement).
// The first-person view transforms these; collision never reads them.
interface Box3 { center: Vec3; size: Vec3; color: Color; roof?: Color }
interface Model3D { boxes: Box3[] }

type Color = Brand<'Color', string>;  // '#rrggbb'


// ----------------------------------------------------------------------------
// Obstructions — static things that block the car and get drawn. A discriminated
// UNION (not a base class). Each variant composes Placement + Footprint + Model3D
// plus its own extras. Parked cars live here: an obstruction-car is far closer
// to a building than to the UserCar.
// ----------------------------------------------------------------------------
interface Tree {
  kind: 'tree';
  placement: Placement;
  footprint: Footprint;   // ~ the foliage; a row of them reads as a wall
  model: Model3D;         // trunk + foliage boxes
}
interface Building {
  kind: 'building';
  placement: Placement;
  footprint: Footprint;
  model: Model3D;
  windows?: boolean;
}
interface House {
  kind: 'house';
  placement: Placement;
  footprint: Footprint;
  model: Model3D;
}
interface ParkedCar {
  kind: 'parkedCar';
  placement: Placement;
  footprint: Footprint;
  color: Color;
}
type Obstruction = Tree | Building | House | ParkedCar;

// CORNER (a concept, not a type).
// At an intersection, an obstruction near where two segments meet has meaning in
// BOTH segments. Leaving the lot, a building on my right shows its FRONT face;
// after I turn right, the SAME building is on my right but I see its SIDE face.
// The model resolves this by storing it as TWO obstructions occupying the same
// physical spot — one in each segment's frame, each with its own Placement
// (along / offset / facing). They share a `physicalId` so the Corner logic can
// keep them consistent (move one, move both). Example: a tree 10 m to my right
// and 5 m before the intersection becomes, after the right turn, the same tree
// 10 m ahead and 5 m off the road — two Placements, one PhysicalThing.
type PhysicalId = Brand<'PhysicalId', string>;
interface CornerTwin {
  physicalId: PhysicalId;  // same real-world object, placed in 2+ segment frames
}
type CornerObstruction = Obstruction & CornerTwin;


// ----------------------------------------------------------------------------
// Danger — the wrong-way deterrent. A wrong turn dead-ends in one of these,
// sitting ON the stub pavement so it blocks you with just enough room to turn
// around. (Distinct from Obstruction: it marks "you went the wrong way".)
// ----------------------------------------------------------------------------
interface DangerZone {
  kind: 'fire' | 'wall';
  footprint: Footprint;   // blocks the car at the end of a wrong stub
}


// ----------------------------------------------------------------------------
// Road segments and the graph that joins them
// ----------------------------------------------------------------------------
type SegmentId = Brand<'SegmentId', string>;
type Surface   = 'lot' | 'road';

interface RoadSegment {
  id: SegmentId;
  name: string;
  surface: Surface;
  dir: Cardinal;           // travel direction (used to lay out the derived map)
  length: Meters;
  width: Meters;           // pavement width
  paintedLines: boolean;

  // Obstructions live in THIS segment's frame. Corner objects are duplicated
  // here from a neighbor via their CornerTwin.
  obstructions: CornerObstruction[];

  start: JunctionId;       // where you enter
  end: JunctionId;         // where you exit (an intersection or a dead end)
}

// A junction is relational: it names the segments it joins and the turn between
// them. It has NO world coordinates — positions at the junction are expressed
// relative to whichever segment you APPROACH on.
type JunctionId = Brand<'JunctionId', string>;
type Junction = Intersection | DeadEnd;

interface Intersection {
  kind: 'intersection';
  id: JunctionId;
  exits: Exit[];           // one per (approach segment -> available turn)
}

// Reading: "approaching on `from`, a `turn` puts you on `to`."
// `correct` marks the route's intended turn; everything else is a wrong way,
// and a wrong way dead-ends in a DangerZone.
interface Exit {
  from: SegmentId;
  turn: Turn;
  to: SegmentId;
  correct: boolean;
  danger?: DangerZone;     // present on wrong exits
}

interface DeadEnd {
  kind: 'deadEnd';
  id: JunctionId;
  danger: DangerZone;      // e.g. the wall behind your parking space; the fire stub
}


// ----------------------------------------------------------------------------
// The user's car — its own type, NOT an obstruction. Its position is a place in
// the graph (which segment, where on it), never an absolute coordinate.
// ----------------------------------------------------------------------------
interface CarLocation {
  segment: SegmentId;
  pos: SegmentPos;         // along + across, in the segment's frame
  heading: Radians;        // relative to the segment axis (0 = pointing "along")
}

interface UserCar {
  location: CarLocation;
  speed: MetersPerSecond;  // uncapped; the brake is the only thing that slows you
  size: { length: Meters; width: Meters };
  accel: MetersPerSecond2; // engine
  brake: MetersPerSecond2; // brake deceleration
}


// ----------------------------------------------------------------------------
// LocalWorld — the slice of the graph the car currently cares about. This is
// what both views consume; neither view walks the whole graph.
// ----------------------------------------------------------------------------
interface LocalWorld {
  here: RoadSegment;       // the segment under the car
  ahead?: Intersection;    // the junction it is approaching
  neighbors: RoadSegment[];// segments reachable/visible from `here`
}


// ----------------------------------------------------------------------------
// Views — projections of the model to the screen. The MODEL never imports these.
//  Frame2D: top-down map. Needs a derived global layout (absolute Vec2 per
//           segment, computed by walking the graph — a view concern).
//  Frame3D: first-person camera, fed the car-relative LocalWorld.
// ----------------------------------------------------------------------------
interface ScreenPt { sx: number; sy: number }  // pixels (plain numbers; screen space)

type Frame2D = (worldPoint: Vec2) => ScreenPt;

interface Camera3D {
  eye: Vec3;
  heading: Radians;
  fov: Radians;
  focalPx: number;
}
type Frame3D = (worldPoint: Vec3, cam: Camera3D) => ScreenPt;
