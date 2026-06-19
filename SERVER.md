# Server

The server is the **zig server** in [`zig-server/`](zig-server/). One process
serves every surface — chat, channels, docs, recent, images/uploads, code,
driving, puzzles, game, learn, settings, admin — over the shared on-disk data
tree.

- Entry: `zig-server/src/server.zig` (routing is a `switch` on the path).
- Build + run: `cd zig-server && zig build && GOPHER_CONFIG=~/AngryGopher/gopher.conf ./zig-out/bin/zig-server` (listens on `:9001`).
- `GOPHER_CONFIG` points `data_dir` (the content tree) and `auth_root` (the shared `~/Auth` account store); unset = repo-relative defaults.
- Markdown conformance: `cd zig-server && zig run src/main.zig` (diffs the renderer against the frozen gold corpus).

## The historical Go server

`server/*.go` is the **original** server — the one being replaced. It and the
zig server never run together; the zig port is a drop-in replacement that
reproduces its behavior surface by surface. Treat the Go tree as historical:
read it for intent if useful, but **new work goes in `zig-server/`**.

## Orientation, not reference

This file points; it doesn't specify. The code is the source of truth for what
the server does — prefer reading `zig-server/src/` over trusting any prose
(here or in comments) that may have drifted.
