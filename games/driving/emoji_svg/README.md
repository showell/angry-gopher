# Vendored emoji art (bake input)

These SVGs are the source art for the Safari critters, one file per animal,
named by its Unicode codepoint (`1f992.svg` is the giraffe 🦒).
`ops/bake_emoji` turns them into polygons in `../wasm/emoji_frames.zig`, so
every build, browser and native, draws the critters as plain polygons.

## Attribution

The artwork is Microsoft's **[Fluent Emoji](https://github.com/microsoft/fluentui-emoji)**,
the **Flat** variant, **MIT** licensed. It was chosen because:

- it draws every animal **full-body, from the side**, which reads well as
  roadside scenery;
- it is **flat, fill-only** vector art, which tessellates cleanly into the
  game's polygons;
- it matches the prod look, the Segoe/Fluent emoji the deployed browser
  renders.

Fluent's *Color* variant is gradient-shaded, richer than flat polygons can
carry.
