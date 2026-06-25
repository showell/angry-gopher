// orders.ts — the day's deliveries. Every house is a potential customer; a
// seeded pseudorandom draw picks which ones actually ordered today. Seeded so a
// reload is reproducible (and a reshuffle is just a new seed).

import type { Pt, Neighborhood } from "./geography.ts";
import { NEIGHBORHOODS, housesOf } from "./geography.ts";

export type House = { id: string; nbhd: string; index: number; at: Pt };

/** Every house on every neighborhood ring, with a stable id. */
export function allHouses(): House[] {
  const out: House[] = [];
  for (const n of NEIGHBORHOODS as Neighborhood[]) {
    housesOf(n).forEach((at, i) => out.push({ id: `${n.name}#${i}`, nbhd: n.name, index: i, at }));
  }
  return out;
}

/** mulberry32 — a tiny, fast, deterministic PRNG. Same seed => same sequence. */
function mulberry32(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Pick `count` distinct houses (by a partial Fisher-Yates shuffle) for `seed`. */
export function chooseOrders(seed: number, count: number): Set<string> {
  const houses = allHouses();
  const idx = houses.map((_, i) => i);
  const rng = mulberry32(seed);
  const n = Math.min(count, idx.length);
  for (let i = 0; i < n; i++) {
    const j = i + Math.floor(rng() * (idx.length - i));
    const tmp = idx[i];
    idx[i] = idx[j];
    idx[j] = tmp;
  }
  const chosen = new Set<string>();
  for (let k = 0; k < n; k++) chosen.add(houses[idx[k]].id);
  return chosen;
}
