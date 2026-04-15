---
id: 5
title: Wiki sidecar reply compose box — too small
source: dm msg=30
status: done
created: 2026-04-15T16:35
updated: 2026-04-15T16:48
---

## What Steve said

> ISSUE: compose box still too small for sidecar replies

## Status

**Done 2026-04-15T16:38.** Textarea in `views/wiki.go` reply form bumped to `width:100%, min-height:240px, rows=12, font-size:15px` — matches the DM compose box.

## Plan

Verify in browser.

## Log

- 2026-04-15T16:35  Raised by Steve after my earlier (insufficient) bump
- 2026-04-15T16:38  Enlarged to match DM compose; server restarted
- 2026-04-15T16:48  Filed as done
