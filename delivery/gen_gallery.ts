// Render the home-page gallery image for Seattle Delivery (gallery/delivery.svg):
// the app's REAL Seattle map — coastlines, lakes, Mercer Island, the road network,
// the I-5 spine and bridges, the warehouse — drawn straight from geography.ts (single
// source of truth, no duplicated geometry), with 100 homes coloured across the 8 truck
// routes and tour lines routed over the actual road graph (shortest paths).
//
// Stylized framing (cropped to the gallery's aspect) but faithful content, the same way
// ops/gallery_cat renders the cat from the game's own code. Run via ops/gallery_delivery
// (node --experimental-strip-types). Re-run if the map geometry changes.
//
// The only thing kept in sync by hand is the palette below — mirror of map_view.ts's
// TRUCK_COLORS + COLOR (module-local there, not exported).
import { writeFileSync } from "node:fs";
import {
  WEST_SHORE, EAST_SHORE, MERCER_ISLAND, PUGET_SOUND, LAKE_UNION,
  CANAL_WEST, CANAL_EAST, UNION_BAY, NEIGHBORHOODS, ROADS, BRIDGES,
  WAREHOUSE, TRUCK_ANCHORS, MAP_W, MAP_H, housesOf, gateOf, nodeAt,
} from "./geography.ts";
import type { Pt } from "./geography.ts";

const TRUCK_COLORS = ["#1c6fd6", "#e8590c", "#2f9e44", "#d6336c", "#a0521d", "#7048e8", "#b8860b", "#343a40"];
const COL = {
  westLand: "#e7e3ea", eastLand: "#e7eede", water: "#9fcfe6", waterEdge: "#6fb2d2",
  island: "#eef3df", road: "#cfc7bb", roadCasing: "#b3aa9c", home: "#cdc6b8",
  homeEdge: "#a9a094", depot: "#c0392b",
};

const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.y - b.y);
const nb = (name: string) => NEIGHBORHOODS.find((n) => n.name === name)!;
const homeNbs = NEIGHBORHOODS.filter((n) => n.houses > 0);

// --- assign each home-neighborhood to its nearest truck anchor; pin anchors ---
const assign = new Map<string, number>();
for (const n of homeNbs) {
  let best = 0, bd = Infinity;
  for (let t = 0; t < 8; t++) {
    const d = dist(n.center, nb(TRUCK_ANCHORS[t]).center);
    if (d < bd) { bd = d; best = t; }
  }
  assign.set(n.name, best);
}
TRUCK_ANCHORS.forEach((a, t) => assign.set(a, t));

// --- pick 100 customers, round-robin across neighborhoods (evenly spread) ---
const order = [...homeNbs].sort((a, b) => a.center.y - b.center.y || a.center.x - b.center.x);
const customers = new Map<string, number[]>(homeNbs.map((n) => [n.name, []]));
let picked = 0;
for (let ring = 0; picked < 100; ring++) {
  for (const n of order) {
    if (ring < n.houses) { customers.get(n.name)!.push(ring); if (++picked >= 100) break; }
  }
}

// --- road graph (ROADS + BRIDGES) for shortest-path route lines ---
const plen = (pts: Pt[]) => pts.slice(1).reduce((s, p, i) => s + dist(pts[i], p), 0);
const adj = new Map<string, [string, number][]>();
const edgeDraw = new Map<string, Pt[]>();
const addEdge = (a: string, b: string, pts: Pt[]) => {
  const w = plen(pts);
  (adj.get(a) ?? adj.set(a, []).get(a)!).push([b, w]);
  (adj.get(b) ?? adj.set(b, []).get(b)!).push([a, w]);
  edgeDraw.set(a + "|" + b, pts); edgeDraw.set(b + "|" + a, [...pts].reverse());
};
for (const [a, b] of ROADS) addEdge(a, b, [nodeAt(a), nodeAt(b)]);
for (const br of BRIDGES) {
  for (let i = 0; i < br.nodes.length - 1; i++) {
    const a = br.nodes[i], b = br.nodes[i + 1];
    addEdge(a, b, [nodeAt(a), ...br.waters[i], nodeAt(b)]);
  }
}
function dijkstra(src: string) {
  const D = new Map<string, number>([[src, 0]]); const prev = new Map<string, string>();
  const seen = new Set<string>();
  while (true) {
    let u: string | null = null, ud = Infinity;
    for (const [k, d] of D) if (!seen.has(k) && d < ud) { ud = d; u = k; }
    if (u === null) break;
    seen.add(u);
    for (const [v, w] of adj.get(u) ?? []) {
      if (ud + w < (D.get(v) ?? Infinity)) { D.set(v, ud + w); prev.set(v, u); }
    }
  }
  return { D, prev };
}
function pathPts(prev: Map<string, string>, src: string, dst: string): Pt[] {
  const chain = [dst];
  while (chain[chain.length - 1] !== src) chain.push(prev.get(chain[chain.length - 1])!);
  chain.reverse();
  let pts: Pt[] = [];
  for (let i = 0; i < chain.length - 1; i++) {
    const seg = edgeDraw.get(chain[i] + "|" + chain[i + 1])!;
    pts = pts.concat(i === 0 ? seg : seg.slice(1));
  }
  return pts;
}

// --- SVG helpers ---
const P = (pts: Pt[]) => pts.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(" ");
const out: string[] = [];
const poly = (pts: Pt[], fill: string, edge?: string, w = 1.4) =>
  out.push(`  <polygon points="${P(pts)}" fill="${fill}"${edge ? ` stroke="${edge}" stroke-width="${w}"` : ""}/>`);
const line = (pts: Pt[], color: string, w: number, opacity = 1) =>
  out.push(`  <polyline points="${P(pts)}" fill="none" stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" opacity="${opacity}"/>`);

// land
out.push(`  <rect x="0" y="0" width="${MAP_W}" height="${MAP_H}" fill="${COL.westLand}"/>`);
out.push(`  <rect x="540" y="0" width="${MAP_W - 540}" height="${MAP_H}" fill="${COL.eastLand}"/>`);
// water
poly(PUGET_SOUND, COL.water, COL.waterEdge, 2);
poly([...WEST_SHORE, ...[...EAST_SHORE].reverse()], COL.water, COL.waterEdge, 2);   // Lake Washington
line(CANAL_WEST, COL.water, 15);
line(CANAL_EAST, COL.water, 13);
poly(LAKE_UNION, COL.water, COL.waterEdge, 2);
poly(UNION_BAY, COL.water, COL.waterEdge, 2);
poly(MERCER_ISLAND, COL.island, COL.waterEdge, 2);
// roads: casing then surface, gate-to-gate (surface) / node-chain (bridges)
const segs: Pt[][] = ROADS.map(([a, b]) => [gateOf(a, nodeAt(b)), gateOf(b, nodeAt(a))]);
for (const br of BRIDGES) {
  for (let i = 0; i < br.nodes.length - 1; i++) {
    const a = br.nodes[i], b = br.nodes[i + 1], w = br.waters[i];
    segs.push([gateOf(a, w[0] ?? nodeAt(b)), ...w, gateOf(b, w[w.length - 1] ?? nodeAt(a))]);
  }
}
for (const s of segs) line(s, COL.roadCasing, 6);
for (const s of segs) line(s, COL.road, 3.4);
// neighborhood ring roads
for (const n of homeNbs)
  out.push(`  <circle cx="${n.center.x}" cy="${n.center.y}" r="${n.ringRadius}" fill="none" stroke="${COL.roadCasing}" stroke-width="1.6" opacity="0.6"/>`);
// all homes, pale
const HS = 5;
for (const n of homeNbs)
  for (const h of housesOf(n))
    out.push(`  <rect x="${(h.x - HS / 2).toFixed(1)}" y="${(h.y - HS / 2).toFixed(1)}" width="${HS}" height="${HS}" fill="${COL.home}" stroke="${COL.homeEdge}" stroke-width="0.7"/>`);
// route tour lines over the road graph
for (let t = 0; t < 8; t++) {
  const stops = homeNbs.filter((n) => assign.get(n.name) === t).map((n) => n.name);
  if (!stops.length) continue;
  const seq: string[] = []; let cur = "FC"; const pool = [...stops];
  while (pool.length) {
    const { D } = dijkstra(cur);
    let bi = 0, bd = Infinity;
    pool.forEach((n, i) => { const d = D.get(n) ?? Infinity; if (d < bd) { bd = d; bi = i; } });
    seq.push(pool[bi]); cur = pool[bi]; pool.splice(bi, 1);
  }
  let full: Pt[] = []; let prevNode = "FC";
  for (const s of seq) {
    const { prev } = dijkstra(prevNode); const pp = pathPts(prev, prevNode, s);
    full = full.length ? full.concat(pp.slice(1)) : pp; prevNode = s;
  }
  if (full.length) line(full, TRUCK_COLORS[t], 3, 0.9);
}
// customer homes, coloured by route
const CS = 7;
for (const n of homeNbs) {
  const hs = housesOf(n), color = TRUCK_COLORS[assign.get(n.name)!];
  for (const i of customers.get(n.name)!) {
    const h = hs[i];
    out.push(`  <rect x="${(h.x - CS / 2).toFixed(1)}" y="${(h.y - CS / 2).toFixed(1)}" width="${CS}" height="${CS}" rx="1" fill="${color}" stroke="#ffffff" stroke-width="0.9"/>`);
  }
}
// depot (warehouse)
const { x: wx, y: wy } = WAREHOUSE;
out.push(`  <circle cx="${wx}" cy="${wy}" r="14" fill="${COL.depot}" opacity="0.18"/>`);
out.push(`  <rect x="${wx - 9}" y="${wy - 9}" width="18" height="18" rx="3" fill="${COL.depot}" stroke="#ffffff" stroke-width="2"/>`);
out.push(`  <circle cx="${wx}" cy="${wy}" r="3.2" fill="#ffffff"/>`);

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 12 1000 700" width="600" height="420" role="img" aria-label="Seattle Delivery — a map of Seattle with 100 homes split across 8 coloured delivery routes fanning out from the warehouse">
  <!-- Generated by delivery/gen_gallery.ts from geography.ts: the app's real Seattle map
       (coastlines, lakes, Mercer Island, roads, I-5 spine, bridges, depot) with 100 homes
       coloured across the 8 truck routes. Framed to the gallery ratio. -->
${out.join("\n")}
</svg>
`;
const dest = new URL("../gallery/delivery.svg", import.meta.url);
writeFileSync(dest, svg);
console.log(`wrote gallery/delivery.svg  (${picked} customers, ${homeNbs.length} neighborhoods)`);
