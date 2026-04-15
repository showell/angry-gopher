---
id: 14
title: Angry Cat event queue may infinite-loop (potential regression)
source: steve (console, out-of-band)
status: open
created: 2026-04-15T17:28
updated: 2026-04-15T17:28
---

## What Steve said

> ANGRY CAT -> ZULIP (Production) We may have introduced a bug in
> Angry Cat where we infinitely loop in the event queue. I'm
> flagging this here. It's not urgent for now, but it's important.
> I will use the console for out-of-band things like this.

## Status

Not started. Flagged by Steve as out-of-band (console, not in the
DM/wiki channel) because the ANCHOR_COMMENTS stack is for
feature-track talk — production incidents go console-side.

## Plan

- Start in `angry-cat/src/` — grep for `event_queue`, `pollEvents`,
  `getEvents`, the classic Zulip-style long-polling loop names.
- Candidate regressions: did anything in the auth rip (Gopher commit
  `dd08da7`) or the LynRummy / Cat cleanup earlier this session
  change what the event queue expects to receive? A 4xx that used to
  terminate the loop might now silently retry.
- Reproduce: run Cat against Gopher prod, open devtools Network tab,
  watch `/json/events` (or Gopher's equivalent) for rapid-fire calls.
- Add a circuit-breaker: abort after N consecutive failures in a
  short window. Log the cause.

## Log

- 2026-04-15T17:28  Flagged by Steve (console, out-of-band)
