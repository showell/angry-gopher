# The seam: what an application reaches for, and through what

The site's own logic runs unchanged on Linux and on zig-metal-unikernel, a
machine with no operating system. The only thing that differs between the two
is what sits under a small, named seam. This file says where that seam is,
and what still reaches around it.

The test that the seam holds is already a lint: `tools/lint_portable.py`
(run by `ops/check_zig`) walks `router.zig`'s imports — everything this site
serves — and fails if any of it reaches for the host. So "the application
reaches for nothing host-specific" is not an aspiration here; it compiles, or
it does not. This note is about shrinking the surface the host must implement
on the far side of that line.

## What the application sees, and the file that provides it

| what the application reaches for | the seam | provided by |
|---|---|---|
| the clock | `Io.Clock.now(.real, io)` | the `io` value |
| randomness | `io.random(buf)` — OS-seeded CSPRNG | the `io` value |
| every data file it keeps | zig-webbox's `store.zig` (`read`, `write`, `stat`, `readAt`, …), taking `io` | the `io` value's disk |
| a live stream (SSE) | `bus.zig` — the app describes a `Kept`; the host serves it | `Hub`/`Bus` |
| where its data lives | `roots.zig` — six roots from two directories | the host's `main` |
| a request's inputs | zig-webbox's `http.zig` — `target`, `header`, `cookie`, `queryValue` (OWNED copies) | `std.http.Server.Request` |
| a request's outputs | `req.respond(...)` directly, plus `http.notFound`/`redirect` | `std.http.Server.Request` |
| a log line | — (none; the host logs) | the host |

Three things carry the whole seam:

- **The `io` value** (`std.Io`). One handle, threaded through nearly every
  call, carries the clock, the CSPRNG, and the disk the Store reads. A host
  builds it: on Linux it is `std.Io.Threaded`, backed by the OS; on
  zig-metal-unikernel it is the kernel's own, backed by the volume and a metal
  entropy source. The application never asks *which* — it asks `io`. This is
  why clock and random, which a note might expect to find reached around the
  seam, are already inside it: `Io.Clock.now` and `io.random` are the seam.

- **The Store** (zig-webbox's `store.zig`). Every file the application keeps goes through
  it, and it enforces **FAT's rules on every host** (names, case-folding, the
  folder-entry ceiling) so Linux cannot quietly accept what the volume will
  refuse.

- **The Bus** (`bus.zig`). The application describes a stream and records a
  `Kept`; the host keeps it — blocking on a per-connection task on Linux,
  rendering the next arrived event on the single loop on metal. One source,
  two hosts.

Config is a near-miss worth naming: the *source* differs (Linux reads
environment variables and a config file in webbox's `linux_config.zig`; metal
reads `zig-metal-unikernel.conf`), but
both end at `roots.point`, so the application proper never sees the
difference — only the two `main`s do. That is the seam working as intended:
the host-specific part is confined to the host's entry point.

## What is still reached around the seam

- **The response half of HTTP.** The *input* half is already behind the seam:
  zig-webbox's `http.zig` holds the only code allowed to touch `req.head.*`, enforced by
  `tools/lint_head_access.py`, so a head value can never dangle past the body
  read. The *output* half is not: **many of the site's files call
  `req.respond(...)` on `std.http.Server.Request` directly**, with their own
  `extra_headers` (`grep -l 'respond(' zig-server/src/*.zig | wc -l` counts
  them). So the application still depends on the whole
  `std.http.Server` response API, and the host must provide exactly that — a
  large surface, and the one place the "reaches for nothing host-specific"
  property is carried by `std.http` being present on both hosts rather than by
  a small interface the application owns.

- **Nothing else of substance.** These go *through* the seam, not around
  it:
  - **uploads** — served by the `stat`/`readAt` of zig-webbox's `store.zig` (the Range path
    reads positionally through the Store), not a direct host read;
  - **sessions** — the secret is read through the Store; signing and verifying
    are pure (`users.zig`), so no host call;
  - **the site's own files** — `pages/`, `gallery/`, `downloads/` are read
    through `store.read`, not `std.fs`; only `brand.zig`'s images
    are `@embedFile`d into the binary, which is no host call at all.

- **The log.** The application has no log seam, because it does not log — the
  *host* logs (the serial console on metal, `std.debug.print` on Linux), and
  `/admin/host` reports the host's own facts. That is no problem; it would
  only become one if the application wanted to emit a line both hosts
  render the same way, and then it would want a seam like the others rather
  than a reach for the host.

## The next subtraction, if it is taken

Pull `req.respond` behind zig-webbox's `http.zig`, the way `req.head` is: give `http.zig`
success responses to match its error ones (`ok`, `json`, `html`, … beside
`notFound` and `redirect`), move every handler's `req.respond(...)` to them,
and add a lint beside `lint_head_access.py` that lets only zig-webbox's `http.zig` call
`req.respond`. The application's dependency on `std.http.Server` would then be
`http.zig`'s small surface. It moves calls, not logic, so zig-metal-unikernel's
chat judge (`probe/judge_gopher.py`), which compares every page from metal and
from Linux byte for byte, would show it changed nothing. It is not scheduled.
