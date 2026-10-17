# zig-server

The Angry Gopher server, in zig — every surface (home, login, chat, docs, the
Lyn Rummy `/game` + `/puzzles`, `/driving`, `/admin`, `/settings`) served from
one statically-linked binary over a shared on-disk data tree. The code is the
source of truth for what the server does; this file points.

## Toolchain

zig **0.16.0** (`zig version`).

## Server (`src/server.zig`)

`server.zig` is the entry point, and the `webbox` library
([zig-webbox](https://github.com/showell/zig-webbox), the sibling checkout
`../../zig-webbox`) does the serving: the portable module `webbox`, which
the rest of the server imports by name, and its Linux host, the module
`webbox_linux` (its `linux_host.zig`), which listens on **:9001**,
runs each accepted connection as its own task on the `std.Io` thread pool,
and hands each
request to `router.zig`, which routes by path prefix to the per-surface
handlers (`chat.zig`, `puzzles.zig`, `game.zig`, `driving.zig`, …). The port
is `GOPHER_PORT` (default 9001); `data_dir` + auth come from
`GOPHER_CONFIG`. `server.zig` holds what is this application's own about
that: its name, its variables, the game store's floor, its startup lines.
Handlers take the turn one at a time (the `turn` lock in webbox's
`linux_host.zig`), as on metal's single loop.

Front-end assets that live elsewhere in the repo (the Elm/TS bundles, the
Safari and chess WASM cores, the chat client, the puzzle catalogs) are baked
in at compile time via `build.zig` `@embedFile`. The site's own files —
`pages/`, `gallery/`, `downloads/` — are read from the working directory.

`build.zig` is where cross-package embedding is wired up: `@embedFile` can't
reach outside its own package dir, so each external asset is declared there as
a named import. `assets.zon` lists every embedded asset and the `ops/` script
that builds it; `ops/build_embedded` runs those scripts. A fresh clone has
none of the built assets, so a bare `zig build` fails. Build and run with:

```
ops/start                        # build every embedded asset + zig + run on :9001
```

The server was ported from a Go original (`main.go` + `server/*.go`); that tree
is in git history.

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

- `~/showell_repos/gopher-gold/gold.jsonl` — the real corpus of chat messages
  and docs, in a separate private git repository on the dev box only (it
  embeds real user messages; it has no remote). **Without it the harness
  stops**, naming the file. To make it again from a backup's `chat/`
  (a data_dir's), `cd zig-server && zig build markdown-regression -- --capture
  CHAT_ROOT`: every transcript's messages and every user doc, rendered now.
  `git -C ~/showell_repos/gopher-gold log` says which backup it came from.
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
