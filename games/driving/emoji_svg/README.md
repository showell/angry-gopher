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
| `1f402.svg` | bull 🐂 (Ox) | U+1F402 |
| `1f404.svg` | cow 🐄 | U+1F404 |
| `1f416.svg` | pig 🐖 | U+1F416 |

## Attribution

Artwork from Microsoft **[Fluent Emoji](https://github.com/microsoft/fluentui-emoji)**
(the **Flat** variant), **MIT** licensed. Chosen because:

- it's **full-body, side-view** art for every animal — Twemoji draws some (rhino, zebra) as
  head-only faces, which read as a bug in a roadside-scenery context;
- it's **flat fill-only** vector (no strokes, transforms, or gradients), which tessellates
  cleanly into the game's polygon seam;
- it matches the **prod look** (the Segoe/Fluent emoji lineage the deployed browser renders).

Fluent's *Color* variant is gradient-shaded (richer, but the flat-polygon seam can't reproduce
it) — see the bull-shading work if/when it lands.
