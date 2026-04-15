---
id: 4
title: Every Claude reply ends with link to Steve↔Claude landing page
source: dm msg=22
status: done
created: 2026-04-15T16:29
updated: 2026-04-15T17:07
---

## What Steve said

> FEATURE REQUEST: when Claude sends me a reply, it should always end with a link to the Steve-Claude landing page

## Status

**Done 2026-04-15T17:07.** `dm.SendDM` now appends a landing-page link to Claude-sent DMs. Skip if the content already contains `/gopher/claude-issues` (so Claude can manually include a more specific issue link and the auto-append stays out of the way).

Future: upgrade to per-issue links when there's a mapping from DM content → specific issue. For now, index link is enough.

## Plan

- Short term: Claude manually appends link to each outgoing DM
- Medium term: helper in the outgoing DM code path that auto-appends if Claude is the sender
- Better: each DM is about one issue — link the *specific* issue page, not the index

## Log

- 2026-04-15T16:29  Raised
- 2026-04-15T16:48  Filed
