# Server

The server is the **zig server** in [`zig-server/`](zig-server/). One process
serves every surface — chat, channels, docs, recent, images/uploads, code,
driving, puzzles, game, learn, settings, admin — over the shared on-disk data
tree.

- Entry: `zig-server/src/server.zig` (routing is a `switch` on the path).
- Build + run: `cd zig-server && zig build && GOPHER_CONFIG=~/AngryGopher/gopher.conf ./zig-out/bin/zig-server` (listens on `:9001`).
- `GOPHER_CONFIG` points `data_dir` (the content tree) and `auth_root` (the shared `~/Auth` account store); unset = repo-relative defaults.
- Markdown dialect regression: `ops/check_markdown` (renders every frozen corpus case with the renderer and asserts no drift; the renderer is the source of truth, the gold is a frozen baseline — no external oracle).

## History

The server was ported from a Go original (`main.go` + `server/*.go`). That tree
has been **removed** — it lives in git history if you ever need to read the old
implementation for intent. All work is in `zig-server/`.

## Orientation, not reference

This file points; it doesn't specify. The code is the source of truth for what
the server does — prefer reading `zig-server/src/` over trusting any prose
(here or in comments) that may have drifted.
