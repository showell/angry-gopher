# webbox (angry-gopher's copy)

**webbox**, a web server in a box: a small Zig library an application is
built on. The application exports a site (its routes, its pages, its store);
webbox does the HTTP, the cookies, the streams and the disk; a host runs it.

This folder is angry-gopher's own copy of the library, taken whole from
[zig-webbox](https://github.com/showell/zig-webbox) so that angry-gopher
builds on a web stack of its own. The two now change apart. The copy keeps
the original's shape: the `host_io` seam, the metal-portable design, the
one-handler contract and the library's own tests.

**How angry-gopher uses it:** `zig-server/build.zig.zon` names it as the
`webbox` dependency (`.path = "webbox"`). `ops/check_zig` runs its `zig
build test` here, and the server's lints read its `src/` beside
`zig-server/src`. zig-metal-unikernel builds `gopher.elf` with webbox from
its own sibling checkout of [zig-webbox](https://github.com/showell/zig-webbox),
apart from this copy; both repos were retired from this box on 2026-11-18.

## The modules

- **`webbox`** (`src/webbox.zig`): the portable library, what an
  application's code imports.
- **`webbox_linux`** (`src/webbox_linux.zig`): the Linux host, for a Linux
  `main` alone.
- **`host_io`** (`src/host_io_std.zig`): the one file that names the host,
  std's `Io` here.

An application takes all three from `b.dependency("webbox", ...)` and
imports them by module name. The two index files, `src/webbox.zig` and
`src/webbox_linux.zig`, list every public module with a line on each.

## For a host

A host runs a `site.Site(App)`. `src/site.zig`'s header and its `Host`, and
`src/wake.zig`, are the authority; this is the map.

- **Three calls, in order:** `mem_meter.init(base)` before anything else;
  `start(io, Host)` once, before the first request; then `route` per
  request, serving or dropping the stream it answers (`bus.serveKept`,
  `bus.nextFrame`, `bus.drop`).
- **`Host`** is everything a host supplies, once: the data and secrets
  roots, free space, the trusted proxy, and optional facts, logs and fetch.
- **`between(io, Now) Wake`** is the application's work between requests,
  a slice at a time. `Wake` says when it next needs a turn: `more` (now),
  `at` (a time on the awake clock) or `idle` (until a request or its fetch
  ends).
- **The fetch** (`host_fetch`): one GET at a time, started from `between`
  and read on a later call. A host offers it as a `Fetcher`, with outcomes
  as `Outcome`. On Linux it is `linux_fetch`, on a thread of its own.
- **The Linux host** (`webbox_linux.linux_host`), configured by `Env` and
  `Options`, steps `between` on its own thread, under the turn, and sleeps
  on a doorbell that every handler's end rings, until the site's `Wake.at`
  or a ring.

## For an application: the hosted root

An application's build hands its hosts one module, its **hosted root**,
which exports two declarations:

- **`site`**: `webbox.site.Site(App)`, where `App` is the application's
  table; `src/site.zig` (above `Site`) says what it declares.
- **`hosting`**: what only the application can say about itself: `name`,
  `data_name`, `whole_read_max`, `cache_largest_most` and
  `describeStart(report, writer)`. zig-metal-unikernel's kernel requires the
  last four and says so at compile time (its
  [probe/gopher.zig](https://github.com/showell/zig-metal-unikernel/blob/master/probe/gopher.zig));
  a Linux `main` uses what it needs.

The Linux host runs it from the application's own `main`; the kernel runs it
through `addAppKernel` (zig-metal-unikernel's `build.zig`). An application
answers from `/` and makes its page URLs relative, so it can be mounted
under any prefix.

## Combining applications

`src/combo.zig` (`webbox.combo`) makes several applications one hosted root:

    const combined = webbox.combo.Mount(@import("dog_park"), &.{
        .{ .prefix = "/todo", .root = @import("roc_todo") },
    });
    pub const site = combined.site;
    pub const hosting = combined.hosting;

The primary keeps `/` and the host's data and secrets roots. Each mount
answers under its prefix (one segment of `[a-z0-9-]`) with the prefix
stripped (`http.stripTarget`, `http.restoreTarget`); a bare prefix 303s to
itself with a slash; its files are `<data>/<name>` and `<auth>/<name>`.
Families, body limits, uploaders, `between` and `hosting` compose.
`src/combo.zig`'s header gives the rule for each, and its limits: it leaves
URLs, bus keys and nesting as they are.

**A combination's build lives in its primary's repo**: its root module, its
Linux `main`, its serve step and its kernel (`addAppKernel` with `.parts`).
Two pitfalls:

- **Two Roc applications in one binary** share Roc's four runtime symbols.
  The combination's root declares `pub const roc_hooks =
  @import("roc_hooks");` (from roc-webbox's `src/roc_hooks.zig`), and the
  kernel's root forwards it.
- **One Roc compiler per combination:** the primary's, passed down as
  `-Droc`. Each Roc application pins its version in a `roc-version` file,
  and pins that disagree fail at configure.

## Checks

    zig build test          # the library's tests: seconds

`test` includes the library's own shape (`src/library_test.zig`: what each
half may import and reach). `-Dtest-filter=TEXT` runs the tests whose names
contain it; `-Dtest-timing` prints each test's time, slowest first.
`ops/check_zig` runs `zig build test` here.

`build.zig` also keeps the original's `consumers` step, which runs the
sibling repos' checks against a zig-webbox checkout with them beside it.
