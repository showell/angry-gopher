---
id: 8
title: Richer notification popups — more info, more room
source: dm msg=35
status: done
created: 2026-04-15T16:40
updated: 2026-04-15T16:53
---

## What Steve said

> ISSUE: Put a lot more information in the notification messages. There is plenty of room.

## Status

**Done 2026-04-15T16:53.** Notification widget is now a 420px-wide card with sender, kind-badge (DM / WIKI-COMMENT), summary, body snippet (up to 200 chars), and an "open →" link. `notify.Event` gained `Kind`, `Sender`, `Snippet` fields; DM + wiki-reply senders populate them.

## Plan

- Expand the `notify.Event` struct to carry snippet, kind (dm/wiki), sender, relative time
- In `NotificationWidget` JS, render as a multi-line card: sender name, kind tag, first ~160 chars of body, "open →" link
- Make it wider (current width is too narrow for readable content)
- Consider showing last N events stacked, not just the most recent

## Log

- 2026-04-15T16:40  Raised
- 2026-04-15T16:48  Filed
