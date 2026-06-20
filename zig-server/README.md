# zig-server

The Angry Gopher server, in zig — every surface (home, login, chat, docs, the
Lyn Rummy `/game` + `/puzzles`, `/driving`, `/admin`, `/settings`) served from
one statically-linked binary over a shared on-disk data tree. It was ported from
a Go original (now removed); the repo-root `SERVER.md` has the history.

## Toolchain

zig **0.16.0** (`zig version`).

## Server (`src/server.zig`)

`server.zig` is the entry point: it listens on **:9001**, runs each accepted
connection as its own task on the `std.Io` thread pool (so long-lived SSE
streams don't starve other connections), and routes by path prefix to the
per-surface handlers (`chat.zig`, `puzzles.zig`, `game.zig`, `driving.zig`, …).
The port is hardcoded; `data_dir` + auth come from `GOPHER_CONFIG`.

Front-end assets that live elsewhere in the repo (the Elm/TS/driving bundles,
the chat client, the puzzle catalogs) are baked in at compile time via
`build.zig` `@embedFile`, so the binary is self-contained — no runtime file
dependencies.

```
ops/start                        # build bundles + zig + run on :9001
# or, for just /driving:
ops/build_driving && cd zig-server && zig build run
```

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
