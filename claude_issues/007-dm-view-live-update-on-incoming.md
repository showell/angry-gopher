---
id: 7
title: DM conversation view should live-update when Claude sends a new DM
source: dm msg=34
status: done
created: 2026-04-15T16:40
updated: 2026-04-15T16:53
---

## What Steve said

> QUESTION: Is it intentional that when your DM arrives, the DM view only updates the message list when I click on the notification?

## Status

**Done 2026-04-15T16:53.** DM conversation page now subscribes to the SSE activity stream. When an incoming event has `kind=dm` and its URL matches the current conversation, the message appends in place (highlighted yellow) and auto-scrolls to bottom. Truncated at the 200-char snippet limit for now; click-through to refresh still shows full body.

## Plan

- Extend the `/gopher/sse/claude-activity` stream to carry payload `{from, to, content, url}`
- In `renderDMConversation`, subscribe; when incoming event matches current `otherID`, append the message div in place
- Same append-in-place DOM code the Send handler already has — just triggered by SSE instead of fetch response

## Log

- 2026-04-15T16:40  Raised
- 2026-04-15T16:48  Filed
