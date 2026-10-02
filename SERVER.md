# Server

The server is the **zig server** in [`zig-server/`](zig-server/). One process
serves every surface — chat, channels, docs, recent, images/uploads, code,
driving, puzzles, game, learn, settings, admin — over the shared on-disk data
tree.

- Entry: `zig-server/src/server.zig`; routing is `route()` in `zig-server/src/router.zig`, a prefix match per surface.
- Build + run: `cd zig-server && zig build && GOPHER_CONFIG=~/AngryGopher/gopher.conf ./zig-out/bin/zig-server` (listens on `:9001`).
- `GOPHER_CONFIG` points `data_dir` (the content tree) and `auth_dir` (the shared `~/Auth` account store); unset = repo-relative defaults. `GOPHER_PORT`, `GOPHER_BIND` and `GOPHER_TRUSTED_PROXY` set the port, the address, and whose `X-Forwarded-For` is believed.
- Markdown dialect regression: `ops/check_markdown` (renders every frozen corpus case with the renderer and asserts no drift; the renderer is the source of truth, the gold is a frozen baseline — no external oracle).

## History

The server was ported from a Go original (`main.go` + `server/*.go`). That tree
has been **removed** — it lives in git history if you ever need to read the old
implementation for intent. All work is in `zig-server/`.

## Orientation, not reference

This file points; it doesn't specify. The code is the source of truth for what
the server does — prefer reading `zig-server/src/` over trusting any prose
(here or in comments) that may have drifted.
