---
id: 14
title: Angry Cat event queue may infinite-loop (potential regression)
source: steve (console, out-of-band)
status: done
created: 2026-04-15T17:28
updated: 2026-04-15T18:30
---

## What Steve said

> ANGRY CAT -> ZULIP (Production) We may have introduced a bug in
> Angry Cat where we infinitely loop in the event queue. I'm
> flagging this here. It's not urgent for now, but it's important.
> I will use the console for out-of-band things like this.

## Status

**Done 2026-04-15T18:30.** Root-caused and fixed. Actual symptom
came from the **Zulip** path, not Gopher — Steve saw `Queue error,
re-registering... API usage exceeded rate limit`.

## Root cause

`src/backend/event_queue.ts:87` used a bare `fetch(...)` for
polling, without `with_retry`. When Zulip returned HTTP 429 with
body `{result:"error", code:"RATE_LIMIT_HIT"}`, the polling loop
misread that as "queue went bad" and called `register_queue()`.
Registering burns *more* quota — every trip through the loop made
the rate limit worse. `register_queue` itself already used
`with_retry`, which is why only the poll path was infinite-looping.

Probably pre-existing latent bug. Today's session pushed more
restart traffic through Zulip, which tripped the limit and exposed
it.

## Fix

Wrapped the poll fetch in `with_retry` — symmetric with
`register_queue`, one-liner. 429 now causes a `Retry-After` sleep
and retry, not a re-registration.

## Log

- 2026-04-15T17:28  Flagged by Steve (console, out-of-band)
- 2026-04-15T18:30  Diagnosed + shipped one-line fix

## Log

- 2026-04-15T17:28  Flagged by Steve (console, out-of-band)
