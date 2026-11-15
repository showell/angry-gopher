# zig-server

The Angry Gopher server, in zig — every surface (home, login, chat, docs, the
Lyn Rummy `/game` + `/puzzles`, `/driving`, `/admin`, `/settings`) served from
one statically-linked binary over a shared on-disk data tree. The code is the
source of truth for what the server does; this file points.

## Toolchain

zig **0.17.0** (`zig version`).

Four of zig's habits catch this server, and `ops/check_zig` guards the
first two:

- **A green `zig build test` does not mean the server compiles.** A test
  build analyses only what some test references, so a type error in a
  function no test calls shows only under `zig build`. `ops/check_zig` runs
  both.
- **A file's tests run only if a test root in `build.zig` reaches it.**
  Importing a file does not enroll its tests; `tools/test_roots.shale` fails
  on a file with tests that no root reaches.
- **Under `zig test`, `@import("root")` is the test runner**, not the
  program's root, so code that peeks at the root works in the build and
  breaks in tests. Make the shared code a generic that the root instantiates
  with `@This()`, as `games/chess/core/tape.zig`'s `Substrate` is.
- **`@min` and `@max` with a comptime bound narrow the result's type**:
  `@min(3, n)` is a `u2`, so `+ 1` on it can overflow. Give the result a
  type (`: usize`) before doing arithmetic on it.

## Server (`src/server.zig`)

`server.zig` is the entry point, and the `webbox` library
([zig-webbox](https://github.com/showell/zig-webbox), the sibling checkout
`../../zig-webbox`) does the serving: the portable module `webbox`, which
the rest of the server imports by name, and its Linux host, the module
`webbox_linux` (its `linux_host.zig`), which listens on **:9001** (the
signed admin scripts are Shale's, the module `shale`, from the sibling
checkout `../../shale`),
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
