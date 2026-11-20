# zig-server

The Angry Gopher server, in Zig: every surface (home, login, chat, docs, Lyn
Rummy's `/game` and `/puzzles`, `/driving`, `/admin`, `/settings`) served
from one statically linked binary over a shared data tree on disk. The code
says what the server does; this file points into it.

## Toolchain

Zig, at the version `build.zig.zon` names (`minimum_zig_version`).

Four of Zig's habits catch this server, and `ops/check_zig` guards the first
two:

- **A green `zig build test` leaves the server's compile unproven.** A test
  build analyses only what some test references, so a type error in a
  function that only the server calls shows under `zig build` alone.
  `ops/check_zig` runs both.
- **A file's tests run only when a test root in `build.zig` reaches it.**
  Importing a file leaves its tests out; `tools/test_roots.shale` fails on a
  file whose tests sit outside every root.
- **Under `zig test`, `@import("root")` is the test runner**, so code that
  peeks at the program's root works in the build and breaks in tests. Make
  the shared code a generic the root instantiates with `@This()`, as
  `games/chess/core/tape.zig`'s `Substrate` is.
- **`@min` and `@max` with a comptime bound narrow the result's type**:
  `@min(3, n)` is a `u2`, so `+ 1` on it can overflow. Give the result a
  type (`: usize`) before doing arithmetic on it.

## Server (`src/server.zig`)

`server.zig` is the entry point. The `webbox` library in `webbox/`, this
repo's copy of [zig-webbox](https://github.com/showell/zig-webbox), does the
serving. Its portable module `webbox` is what the server imports by name;
its Linux host, the module `webbox_linux` (`linux_host.zig`), listens on
**:9001**, runs each connection as a task on the `std.Io` thread pool and
hands each request to `router.zig`. The router matches path prefixes to the
per-surface handlers (`chat.zig`, `puzzles.zig`, `game.zig`, `driving.zig`
and the rest). Handlers take the turn one at a time (the `turn` lock in
`linux_host.zig`), as on metal's single loop. `server.zig` holds what is
this application's own: its name, its variables, the game store's floor,
its startup lines.

The front-end assets from elsewhere in the repo (the Elm and TS bundles, the
Safari and chess WASM cores, the chat client, the puzzle catalogs) are
embedded at compile time. `@embedFile` reaches only inside its own package,
so `build.zig` declares each external asset as a named import.
`assets.zon` lists every embedded asset and the `ops/` script that builds
it, and `ops/build_embedded` runs those scripts. A fresh clone has to build
them before `zig build` succeeds, so build and run with:

```
ops/start                        # build every embedded asset, then zig, then run on :9001
```

The site's own files (`pages/`, `gallery/`, `downloads/`) are read from the
working directory.

## The edge's threat model, as deployed

webbox's `edge.zig` policy assumes runtime safety is on, and it is on in
every build that serves: production is zig-metal-unikernel's ReleaseSafe
kernel, and the Linux build is Debug (`ops/start`, `ops/deploy`; Debug's
checks are a superset of ReleaseSafe's). An out-of-bounds index or copy
panics, and the host restarts. `stress_test.py`'s edge-policy job asserts
that each reject counter moved. The counters reach the watchdog through
`/version`'s `rejects` (`home.zig`).

The bare-metal side of webbox's `bus.zig` mailbox contract (the seeded
simulator at the bottom of that file) is in zig-metal-unikernel's HOST.md,
"Live streams".
