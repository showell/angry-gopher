---
id: 3
title: META — GitHub-like Issues feature
source: dm msg=20
status: done
created: 2026-04-15T16:27
updated: 2026-04-15T17:07
---

## What Steve said

> META: I think I essentially need a Github-like Issues feature.

## Status

**This issue is itself the spike.** The file you're reading is one of the seed records. Landing page + detail route being built right now (2026-04-15 16:48).

## Plan

- File-based: `claude_issues/*.md` with frontmatter
- `/gopher/claude-issues` — index view
- `/gopher/claude-issues/<id>` — detail view (rendered markdown)
- Claude rebuilds files whenever status changes or Steve asks for refresh
- Every Claude DM links to the relevant issue page (#4)

## Log

- 2026-04-15T16:27  Raised by Steve
- 2026-04-15T16:46  Reprioritized to top by msg 40
- 2026-04-15T16:48  Building now
