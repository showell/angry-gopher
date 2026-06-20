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

## Markdown dialect regression harness

The zig renderer (`src/markdown.zig`) **is** the definition of lynrummy's
markdown dialect. `src/main.zig` is its regression harness: it renders every
frozen `{id, md, html}` case (arena reset per message) and asserts the output
still equals the baseline. There is **no external oracle** — `html` is whatever
our renderer produces, frozen and human-reviewed. Three corpora:

- `~/showell_repos/gopher-gold/gold.jsonl` — the real corpus (~2584 chat
  messages + docs; private, it embeds real user messages).
- `adversarial.jsonl` — hand-written hostile corners the real corpus never hit.
- `dialect.jsonl` — where our dialect deliberately departs from vanilla
  CommonMark: inline markup is **per-line**, so `**`, backticks, and `[...]`
  never pair across a hard wrap.

```
ops/check_markdown            # verify (renders all corpora, exits non-zero on drift)
ops/regen_markdown_gold       # re-freeze from the renderer after an INTENTIONAL change
```

Re-baselining is an explicit act (the benchmark pattern: verify never rewrites).
After `ops/regen_markdown_gold`, read the git diff of each corpus and confirm
only the cases you meant to change actually moved. The Go/goldmark toolchain
that originally seeded the gold has been removed; the workflow is pure zig.
