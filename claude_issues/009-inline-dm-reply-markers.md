---
id: 9
title: Inline DM reply markers — annotate the specific msg being replied to
source: dm msg=38
status: done
created: 2026-04-15T16:43
updated: 2026-04-15T17:09
---

## What Steve said

> ISSUE: If you reply to specific DMs, then you can put a link to your reply next to actual message you are replying to. The full reply would show up naturally in chronological order, of course.

## Status

**Done 2026-04-15T17:09.** Each DM gets an "↩ reply" link; clicking prepends `↳ #N` to the compose textarea. On render, that marker parses into a chip "↳ in reply to msg N" (jumps to the original on click via `#msg-N` anchor). No schema change — marker lives in the message content itself; backward-compatible.

**Deferred to v2:** bi-directional chips ("replies: 47, 52") on the original message require a reverse scan of content; easy but skipped for now.

## Plan

- Add optional `reply_to` form field on DM send (msg id being replied to)
- In `renderDMConversation`, if a message has descendants (other rows with `reply_to = this.id`), render a small "replies: msg 47, msg 52" chip next to it with anchor links
- Replies still flow in chronological order; the chip is just a pointer

## Log

- 2026-04-15T16:43  Raised
- 2026-04-15T16:48  Filed
