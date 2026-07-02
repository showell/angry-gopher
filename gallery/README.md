# Gallery

One **stylized, somewhat-faithful** image per app, destined for the home page —
deliberately *not* screenshots (which go stale even on a parked app). Each is a
one-time render or hand-authored asset, committed here as content.

Served by `zig-server/src/gallery.zig` at **`/gallery`** — a hidden-for-now
preview surface (unlinked, but public): one card per app, in home-page order,
showing the image if present or a `pending` placeholder otherwise. Images are read
from this directory at request time and rsync'd by `ops/deploy` (like `blog/posts/`
and `pages/`), not embedded in the binary.

Filenames are `<slug>.png` (or `.svg`), where the slugs match the manifest in
`gallery.zig`:

| slug | app |
|------|-----|
| `delivery` | Seattle Delivery |
| `safari` | Safari Screensaver |
| `chat` | Chat |
| `blog` | Blog |
| `lynrummy` | Play Lyn Rummy |
| `puzzles` | Lyn Rummy Puzzles |

## How each image is made

- **`safari.png`** — `ops/gallery_cat`. Runs the game's REAL cat-drawing code
  (`cat_anatomy.ts` via `catScenery`) against the dependency-free `MiniCanvas`
  rasterizer (`games/driving/gallery_cat.ts`), composing a single dusk-lit cat on
  the road. Faithful because it *is* the app's code; stale-proof for the same
  reason. Re-run if the cat anatomy changes.
- **`delivery.svg`** — `ops/gallery_delivery`. Renders the app's real Seattle map
  straight from `delivery/geography.ts` (coastlines, lakes, Mercer Island, the road
  network, the I-5 spine + bridges, the warehouse), then colours 100 homes across the
  8 truck routes with tour lines routed over the actual road graph (shortest paths).
  Faithful content — the geometry is the app's own, no duplication — but stylized
  framing: cropped to the gallery ratio and given a clean solved-looking allocation
  (nearest-anchor grouping, not the live solver). Re-run if the map geometry changes.
- The rest are **pending** — approach per app still to be decided.
