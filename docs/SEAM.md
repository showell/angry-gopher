# The seam: what an application reaches for, and through what

QUEUE.md item 78 (gopher-metal). A design note, no code. It is the companion to
the essay "a web server in a box": the site's own logic runs unchanged on
Linux and on a machine with no operating system, and the only thing that
differs between the two is what sits under a small, named seam. This writes
down where that seam is today, what still reaches around it, and the smallest
next thing to pull behind it — so Steve can decide what to subtract next.

The test that the seam holds is already a lint: `tools/lint_portable.py`
(run by `ops/check_zig`) walks `router.zig`'s imports — everything this site
serves — and fails if any of it reaches for the host. So "the application
reaches for nothing host-specific" is not an aspiration here; it compiles, or
it does not. This note is about shrinking the surface the host must implement
on the far side of that line.

## What the application sees today, and the file that provides it

| what the application reaches for | the seam | provided by |
|---|---|---|
| the clock | `Io.Clock.now(.real, io)` | the `io` value |
| randomness | `io.random(buf)` — OS-seeded CSPRNG | the `io` value |
| every data file it keeps | `store.zig` (`read`, `write`, `stat`, `readAt`, …), taking `io` | the `io` value's disk |
| a live stream (SSE) | `bus.zig` — the app describes a `Kept`; the host serves it | `Hub`/`Bus` |
| where its data lives | `roots.zig` — six roots from two directories | the host's `main` |
| a request's inputs | `http.zig` — `target`, `header`, `cookie`, `queryValue` (OWNED copies) | `std.http.Server.Request` |
| a request's outputs | `req.respond(...)` directly, plus `http.notFound`/`redirect` | `std.http.Server.Request` |
| a log line | — (none; the host logs) | the host |

Three things carry the whole seam:

- **The `io` value** (`std.Io`). One handle, threaded through nearly every
  call, carries the clock, the CSPRNG, and the disk the Store reads. A host
  builds it: on Linux it is `std.Io.Threaded`, backed by the OS; on
  gopher-metal it is the kernel's own, backed by the volume and a metal
  entropy source. The application never asks *which* — it asks `io`. This is
  why clock and random, which a note might expect to find reached around the
  seam, are already inside it: `Io.Clock.now` and `io.random` are the seam.

- **The Store** (`store.zig`). Every file the application keeps goes through
  it, and it enforces **FAT's rules on every host** (names, case-folding, the
  folder-entry ceiling) so Linux cannot quietly accept what the volume will
  refuse. This is the part item 21 finished moving; it is done.

- **The Bus** (`bus.zig`). The application describes a stream and records a
  `Kept`; the host keeps it — blocking on a per-connection task on Linux,
  rendering the next arrived event on the single loop on metal. One source,
  two hosts.

Config is a near-miss worth naming: the *source* differs (Linux reads
environment variables in `config.zig`; metal reads `gopher-metal.conf`), but
both end at `roots.point`, so the application proper never sees the
difference — only the two `main`s do. That is the seam working as intended:
the host-specific part is confined to the host's entry point.

## What is still reached around the seam

- **The response half of HTTP.** The *input* half is already behind the seam:
  `http.zig` holds the only code allowed to touch `req.head.*`, enforced by
  `tools/lint_head_access.py`, so a head value can never dangle past the body
  read. The *output* half is not: **34 of the site's files call
  `req.respond(...)` on `std.http.Server.Request` directly**, with their own
  `extra_headers`. So the application still depends on the whole
  `std.http.Server` response API, and the host must provide exactly that — a
  large surface, and the one place the "reaches for nothing host-specific"
  property is carried by `std.http` being present on both hosts rather than by
  a small interface the application owns.

- **Nothing else of substance.** The three the item asks after are all
  *through* the seam now, not around it:
  - **uploads** — served by `store.zig`'s `stat`/`readAt` (the Range path
    reads positionally through the Store), not a direct host read;
  - **sessions** — the secret is read through the Store; signing and verifying
    are pure (`users.zig`), so no host call;
  - **the site's own files** — `pages/`, `gallery/`, `downloads/` are read
    through `store.read` (item 61), not `std.fs`; only `brand.zig`'s images
    are `@embedFile`d into the binary, which is no host call at all.

- **The log.** The application has no log seam, because it does not log — the
  *host* logs (the serial console on metal, `std.debug.print` on Linux), and
  `/admin/host` reports the host's own facts. This is a non-problem today;
  it would only become one if the application wanted to emit a line both hosts
  render the same way, and then it would want a seam like the others rather
  than a reach for the host.

## The smallest next subtraction

**Pull `req.respond` behind `http.zig`, the way `req.head` already is.**

- Give `http.zig` the success responses to match its error ones: an `ok`,
  `created`, `json`, `html` (it already has `notFound`, `methodNotAllowed`,
  `redirect`, and the `_ct` content-type constants), each taking the body and
  the headers the handlers pass today.
- Move the 34 files' `req.respond(...)` calls to those, so no file outside
  `http.zig` names `std.http.Server.Request` for output.
- Add a response-access lint beside `lint_head_access.py`: nothing but
  `http.zig` may call `req.respond`. A lint that compiles the rule is what
  keeps the seam from leaking back open (it is how the head side has stayed
  closed).

After it, the application's entire dependency on `std.http.Server` is
`http.zig`'s small surface — read inputs, write outputs — and a host provides
*that*, not the whole of `std.http`. It is the smallest subtraction because it
moves calls, not logic: no handler's behaviour changes, only the name it calls
to send its bytes. It is the *next* one because the input half is already done
and proven, so the response half is the obvious remaining coupling, and the
one that most shrinks what a host must stand up.

(A later, larger subtraction — not this one — would be to let the host provide
`http.zig`'s surface over something other than `std.http.Server` at all, so
metal need not carry a `std.http` server shim. That is a bigger change and a
separate decision; naming the small interface first is the prerequisite.)

## How the judge would show it changed nothing

The chat judge (`probe/judge_gopher.py`) already serves every page from metal
and from the same angry-gopher built for Linux and compares them **byte for
byte** — each conversation, each topic's page, `raw` and `reactions`, every
upload, the docs, the rosters. A subtraction that only moves where a response
is assembled, without changing a byte of it, shows up as the judge's existing
**`N pages, N identical, 0 different`** on both hosts, unchanged. So the
evidence is not a new story but the whole existing suite still passing after
the move — which is exactly the property the seam exists to guarantee: the
application did not notice, and neither did either host's output. The
response-access lint going green is the second half of the proof: the coupling
is not just moved but closed.

## For Steve

The seam is in good shape: the `io` value (clock, random, disk), the Store,
the Bus, and the input half of HTTP are all behind it, and the portable lint
keeps the site from reaching past it. The one real coupling left is the
*output* half of HTTP, spread across 34 files. The smallest next subtraction
is to pull `req.respond` behind `http.zig` and lint it shut, judged by the
existing byte-for-byte suite showing `0 different`. Whether to take it now, or
leave it until after the cutover with the rest of the speed/cleanup work, is
your call; nothing about it is urgent, and nothing about it is risky.
