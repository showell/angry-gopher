# Neighborhood Role Taxonomy

The solver (`solver.ts`) is a general capacitated vehicle-router — Clarke–Wright
savings, 2-opt/or-opt/exchange, a tote-minute urgency term. It knows nothing about
Seattle. But *we* do, and a handful of small hints (`geography.ts`) give the general
algorithm just enough local knowledge to behave the way a real delivery manager
would expect. Every neighborhood plays one of a few **roles**, and those roles fall
straight out of the data — they're not imposed, they're revealed.

The evidence below is an **affinity matrix**: across 100 shifts, where each
neighborhood's totes actually rode. "Loyalty" = the share that went to its dominant
truck. (Snapshot of the current model — 90 orders, `CARRY_COST` 0.1. Tuning the road
network or the fleet will shift the exact numbers; the *tiers* are the durable part.)

Trucks are pinned to anchor regions: **T1** West Seattle · **T2** Magnolia ·
**T3** Ballard · **T4** Green Lake · **T5** Capitol Hill · **T6** Kirkland ·
**T7** Issaquah · **T8** Mercer S.

| neighborhood | loyalty | where its totes go | role |
|---|---|---|---|
| Bellevue | 31% | T6 31 · T4 23 · T3 14 · T5 12 · T7 8 · T8 5 | connector (filler) |
| Medina | 33% | T4 33 · T6 26 · T3 21 · T5 13 | connector (bridgehead) |
| Factoria | 38% | T8 38 · T7 33 · T1 18 · T5 7 | connector (FC-adjacent) |
| Downtown | 39% | T1 39 · T5 25 · T2 19 · T8 9 | spine |
| Beacon Hill | 49% | T1 49 · T5 25 · T2 10 · T8 9 | spine |
| Redmond | 50% | T6 50 · T7 39 | east, shared |
| Mercer N | 52% | T8 52 · T1 16 · T5 15 · T7 15 | sibling |
| U-District | 55% | T4 55 · T3 20 · T5 13 | spine |
| Fremont | 56% | T3 56 · T2 26 | spine |
| Queen Anne | 69% | T2 69 · T3 10 · T5 9 | spine |
| Ballard … West Seattle | 97–100% | their own slot | **anchor** |

## The three tiers

- **Anchors — 97–100% loyal.** Eight far-flung "hard destinations" (the perimeter,
  plus central-but-far Capitol Hill), each *pinned* to a fixed truck slot so the
  manager sees a consistent fleet day to day. Loyal by construction; the 1–3% leak
  is overflow houses diverting when capacity squeezes. West Seattle is the only
  100% — the far SW corner, no other truck ever passes it, so its overflow has
  nowhere else to go. Loyalty by pure isolation. (`TRUCK_ANCHORS` in geography.ts.)
- **Spine — 49–69% loyal.** U-District, Fremont, Queen Anne, Downtown, Beacon Hill:
  the central-west connective tissue. Each has a clear *home* perimeter truck and
  leaks only to its immediate neighbors — Fremont→Ballard, Queen Anne→Magnolia,
  U-District→Green Lake, Downtown/Beacon Hill→West Seattle. The spine quietly
  **partitions** among the trucks that thread it on their way to the corners. Left
  deliberately unanchored: this flexibility is the slack the solver spends to pack a
  tight fleet, and pinning a spine neighborhood would remove it.
- **Connectors — 31–39% loyal.** Bellevue, Medina, Factoria: no home truck, they
  ride with whoever's passing. Bellevue is least loyal *by design* — it's the
  deferred slack-filler (`DEFER_LAST`), held out of construction and dropped into
  whatever truck has room (spread across six trucks here). Medina is the SR520
  bridgehead; Factoria sits on the FC's doorstep and the I-90/Issaquah corridor.

## A second axis: transit gateways (who you pass vs who you visit)

Loyalty asks *whose* totes a neighborhood gets. A different question — how often a truck
merely **drives through** it — reveals a taxonomy orthogonal to the tiers. Measured across
100 shifts as the **threaded : delivered** ratio (routes that passed through without
stopping, vs routes that delivered):

| neighborhood | threaded : delivered | role |
|---|---|---|
| Mercer Island | 330 : 0 | **ghost interchange** — `houses:0`, a routing waypoint nobody ever stops at (the I-90 circle) |
| Factoria | 311 : 117 (2.7:1) | **transit gateway** — the FC's east door + the I-90 east landing |
| Bellevue | 408 : 154 (2.6:1) | **transit gateway** — the universal east gateway off the FC |
| Medina | 345 : 139 (2.5:1) | **transit gateway** — the SR-520 east bridgehead |
| U-District | 256 : 122 (2.1:1) | **transit gateway** — the SR-520 west bridgehead |
| Beacon Hill | 124 : 106 (1.2:1) | **half-gateway** — the I-90 west landing, but with real demand of its own |
| Fremont | 111 : 110 (1.0:1) | **hub-with-demand** — the NW junction ("Center of the Universe"): passed through as often as visited |
| Eastlake | 0 : 110 | **pure destination** — never threaded; its only edges are the severed CH–U-District chain, so `corridorRepair` consolidates any would-be pass-through |

The four true gateways (Factoria, Bellevue, Medina, U-District) are the bridge/FC doors —
~2.5× more pass-throughs than stops. The poles are **Mercer Island** (all transit, the
airside-only terminal you can't leave) and **Eastlake** (all destination, the cul-de-sac
the "no skyway" geography created). Fremont sits dead center — a transit hub that is also
a real place.

## The loop skeleton

A **loop route** crosses the lake on *both* bridges — out via one, home via the other; an
out-and-back on a single bridge doesn't count. Every loop traverses the same mandatory
six-node ring (on **100% of the 100 loops** in a 100-shift run):

```
FC → Bellevue → Medina → [SR-520] → U-District → … west … → Beacon Hill → [I-90] → Mercer Island → Factoria → FC
```

— all four bridgeheads (U-District / Medina on 520, Beacon Hill / Factoria on I-90), the
Mercer interchange, and Bellevue (the FC's east door). The skeleton is fixed; what varies
is the **cargo that makes a route a loop in the first place**: Capitol Hill (69% of loops)
and Eastlake (61%). Those two are the tell — Capitol Hill is reached via I-90/Beacon Hill,
Eastlake via 520/U-District, so a truck serving both *must* go out one bridge and back the
other. **T5 (Capitol Hill) runs ~62 of every 100 loops** — the fleet's designated
lake-spanner. Under this lens the wide-loop/tight-loop pair flips from the all-routes view:
**Eastlake (61% of loops) outranks Fremont (39%)**, because loops enter the west through
520 / U-District — Eastlake's doorstep — while Fremont lives in the NW out-and-back
territory that loops never reach.

## Notes worth keeping

- **"Flexible spine" ≠ "disloyal."** The spine *splits*, but only between a tiny set
  of adjacent trucks — Fremont is 82% on just two (its road neighbors). The genuine
  free agents are the connectors, which scatter wide. The eye reads the spine as
  disloyal because it shows up split in the rare pathological shift; across 100 it's
  concentrated.
- **Redmond is a clean two-way toss-up** (Kirkland 50 / Issaquah 39 — 89% on two
  trucks). It looks disloyal but is perfectly structured: a non-anchor cleanly shared
  by its two adjacent east trucks. Good evidence that dropping it as an anchor was
  right — its neighbors cover it.
- **The Mercer sibling bond is real but loose.** Mercer N rides with Mercer S only
  52% of the time; the rest it's grabbed by I-90 crossers. Nothing forces the pair —
  it's emergent from the cost model (the second sibling is nearly free once you've
  crossed I-90), and it yields to demand when it should.
- **Factoria's spread is the urgency term working.** 89% of it rides T8/T7/T1 — the
  three trucks that pass it *early* leaving or returning to the FC. The tote-minute
  cost pulled it off the far trucks' tails (where it was once delivered dead last)
  and onto whoever serves it fresh.

## A fun rare quirk

On a really light **Green Lake** day, T4 has little of its own to do, so it makes the
broad loop and mops up the stragglers while the other seven trucks mostly stay in
their lane. The roles aren't rigid — when an anchor's region is quiet, its truck
becomes the day's connector. Quirks like this are rare enough to be a feature.
