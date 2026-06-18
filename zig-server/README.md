# zig-server

A work-in-progress port of the Gopher Chat server from Go to zig, growing up
inside the repo it's meant to eventually replace. Started with the **markdown
rendering layer** (`src/markdown.zig`), then the **bcrypt password layer**
(`src/auth.zig`), and now the first real **HTTP surface** (`src/server.zig`).

## Toolchain

zig **0.16.0** (`zig version`).

## HTTP server (`src/server.zig`)

The first served surface: **`/driving`**, the standalone driving toy. Chosen as
the first HTTP target because it's the minimal surface — no auth, no SSE, no
POSTs, no runtime markdown, no persistence — so it isolates the HTTP runtime
itself. It mirrors Go's `server/driving/driving.go`.

The Go→zig analogs it stands up:

| concern            | Go                          | zig                                  |
|--------------------|-----------------------------|--------------------------------------|
| embed assets       | `//go:embed`                | `@embedFile` (wired in `build.zig`)  |
| listen + accept    | `http.ListenAndServe`       | `std.Io.net` listen/accept           |
| request/response   | `net/http`                  | `std.http.Server`                    |
| routing            | a mux                       | a `switch` on the path (no std router) |

Assets that live elsewhere in the repo (the driving bundle) are baked in via
`build.zig` — the **embed.go analog**: `@embedFile` can't reach outside its own
package dir, so each external asset is declared there as a named import.

```
ops/build_driving            # from repo root: builds games/driving/app.js (esbuild)
cd zig-server && zig build run   # serves /driving on http://localhost:9001
```

Port 9001 leaves 9000 free for the Go dev server (`ops/start`), so both run
side by side. Concurrency is one-connection-at-a-time/blocking for now; the real
concurrency + fan-out decision is deferred until Chat's SSE forces it.

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
