# Gallery

One **stylized, faithful-enough** image per app, shown on its home-page card.
Each is a one-time render or a drawn asset, committed here as content, so it
stays true as an app's UI changes.

`zig-server/src/gallery.zig` serves them at **`/gallery/<file>`**. `/gallery`
itself is an unlinked public preview: one card per app, in home-page order,
showing its image or a `pending` placeholder. The images are read from this
folder at request time. Like `pages/`, the folder ships in each
zig-metal-unikernel boot image (`zig-server/assets.zon`'s `.site`).

Each app's `image:` line in `pages/home.txt` names its file, `<slug>.png` or
`<slug>.svg`.

## Authoring rules

- **Anything directional faces RIGHT.** Images sit left of the text on the
  home page, so a subject facing right looks into the page.
- **The image is honest.** It shows only features the app has. Stylized is
  fine; fictional is out.
- **Derive the image from the app's own code** where you can, as
  `safari.png` and `delivery.svg` do: faithful and current by construction.
- **Preview SVG** by rendering it to a PNG with `cairosvg`. A running
  `ops/start` server shows edits at `/gallery` at once; the final call is a
  look in the browser.

## How each image is made

- **`safari.png`**: `ops/gallery_cat` runs the game's own cat-drawing code
  (`cat_anatomy.ts` via `catScenery`) on the `MiniCanvas` rasterizer
  (`games/driving/gallery_cat.ts`), drawing one dusk-lit cat on the road.
  Re-run it when the cat's anatomy changes.
- **`delivery.svg`**: `ops/gallery_delivery` renders the app's Seattle map
  from `delivery/geography.ts` and colours 100 homes across the eight truck
  routes, with tour lines over the real road graph. The framing is
  stylized: cropped to the gallery's ratio, with homes grouped by nearest
  anchor in place of the live solver. Re-run it when the map changes.
- **`chess.svg`**: a Knight's Tour mid-search in the toys' own visual
  grammar (numbered moves, the retracted branch in red, open hops as green
  dots), with a knight and a queen in front, one piece per toy.
- **`chat.svg`, `lynrummy.svg`, `puzzles.svg`**: drawn SVGs (abstract
  message bubbles, a kitchen-table game, a board mid-solve). Each file's
  opening comment describes it.

Shale's card uses `/shale/card.svg`, from the Shale pages.
