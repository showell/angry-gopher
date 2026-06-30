# Vendored emoji art (bake input)

These 8 SVGs are the source art for the Safari critters. `ops/bake_emoji` parses them
into polygons (`../wasm/emoji_frames.zig`) so the WASM draw seam stays polygon-only — there
is no emoji glyph rendered at runtime, in the browser or (later) native.

One file per critter, named by Unicode codepoint:

| file | critter | codepoint |
|------|---------|-----------|
| `1f986.svg` | duck 🦆 | U+1F986 |
| `1f418.svg` | elephant 🐘 | U+1F418 |
| `1f992.svg` | giraffe 🦒 | U+1F992 |
| `1f993.svg` | zebra 🦓 | U+1F993 |
| `1f98f.svg` | rhino 🦏 | U+1F98F |
| `1f402.svg` | bull 🐂 | U+1F402 | **Fluent** (see below) |
| `1f404.svg` | cow 🐄 | U+1F404 |
| `1f416.svg` | pig 🐖 | U+1F416 |

## Attribution

Two sources, both flat fill-only vector art (no strokes, transforms, or gradients) — which is
what tessellates cleanly into the game's polygon seam:

- **Most critters — Twemoji** (the [jdecked/twemoji](https://github.com/jdecked/twemoji) fork),
  **CC-BY 4.0** (https://creativecommons.org/licenses/by/4.0/). Copyright Twitter, Inc and other
  contributors.
- **The bull (`1f402.svg`) — Microsoft [Fluent Emoji](https://github.com/microsoft/fluentui-emoji)**
  ("Ox", Flat variant), **MIT** licensed. It's deliberately the richer one — more articulated than
  the cartoonish herd (legs, shaded muzzle, horns) — because the bull is drawn up close and we want
  it to carry some weight. Fluent's *Color* variant is gradient-based and the flat-polygon seam
  can't reproduce it, so we use the *Flat* variant.
