# zig-server

The Angry Gopher server, in zig — every surface (home, login, chat, docs, the
Lyn Rummy `/game` + `/puzzles`, `/driving`, `/admin`, `/settings`) served from
one statically-linked binary over a shared on-disk data tree. It was ported from
a Go original (now removed); the repo-root `SERVER.md` has the history.

## Toolchain

zig **0.16.0** (`zig version`).

## Server (`src/server.zig`)

`server.zig` is the entry point, and the `webbox` library
([zig-webbox](https://github.com/showell/zig-webbox), the sibling checkout
`../../zig-webbox`) does the serving: the portable module `webbox`, which
the rest of the server imports by name, and its Linux host, the module
`webbox_linux` (its `linux_host.zig`), which listens on **:9001**,
runs each accepted connection as its own task on the `std.Io` thread pool (so
long-lived SSE streams don't starve other connections), and hands each
request to `router.zig`, which routes by path prefix to the per-surface
handlers (`chat.zig`, `puzzles.zig`, `game.zig`, `driving.zig`, …). The port
is `GOPHER_PORT` (default 9001); `data_dir` + auth come from
`GOPHER_CONFIG`. `server.zig` holds what is this application's own about
that: its name, its variables, the game store's floor, its startup lines.

Front-end assets that live elsewhere in the repo (the Elm/TS bundles, the
Safari and chess WASM cores, the chat client, the puzzle catalogs) are baked
in at compile time via `build.zig` `@embedFile`. The site's own files —
`pages/`, `gallery/`, `downloads/` — are read from the working directory.

```
ops/start                        # build bundles + zig + run on :9001
# or, for just /driving:
ops/build_safari_wasm && cd zig-server && zig build run
```

Assets that live elsewhere in the repo (Safari's wasm and blitter) are baked in via
`build.zig` — where cross-package embedding is wired up: `@embedFile` can't
reach outside its own package dir, so each external asset is declared there as a
named import.

```
ops/build_safari_wasm        # from repo root: builds games/driving/safari.wasm
cd zig-server && zig build run   # serves /driving on http://localhost:9001
```

Port 9001 is where `ops/start` serves locally — it runs this same zig binary
(the Go original is gone). Each accepted connection runs as its own task on a
std.Io thread pool, so requests are served concurrently.

## The edge's threat model, as deployed

webbox's `edge.zig` policy assumes runtime safety is on, and it is on every
build that serves: production is zig-metal-unikernel's ReleaseSafe kernel, and the
Linux build is Debug (`ops/start`, `ops/deploy`; Debug's checks are a superset
of ReleaseSafe's). An out-of-bounds index or copy panics, and the host
restarts. `stress_test.py`'s edge-policy job is the test that asserts each
reject counter moved. The counters reach the watchdog (run by hand) through
`/version`'s `rejects` (`home.zig`).

The bare-metal side of webbox's `bus.zig` mailbox contract (the seeded simulator
at the bottom of that file) is zig-metal-unikernel's HOST.md, "Live streams".

## Markdown dialect regression harness

The zig renderer (`src/markdown.zig`) **is** the definition of lynrummy's
markdown dialect. `src/markdown_regression_test.zig` is its regression harness: it renders every
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
