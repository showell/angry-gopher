# zig-server

A work-in-progress port of the Gopher Chat server from Go to zig, growing up
inside the repo it's meant to eventually replace. Started with the **markdown
rendering layer** (`src/markdown.zig`).

## Toolchain

zig **0.16.0** (`zig version`).

## Gold harness

`src/main.zig` reads the private gold corpus
(`~/showell_repos/gopher-gold/gold.jsonl` — 2378 real chat messages + docs,
each `{id, md, html}` where `html` is the Go `RenderChatMarkdown` oracle
output), renders every `md` with the zig renderer (arena reset per message),
and diffs against the oracle. It prints `FAILID\t<id>` per mismatch plus a
running `N/2378 passing` tally.

```
cd zig-server && zig run src/main.zig
```

The port proceeds by making more and more cases pass, easiest/most-common
constructs first.
