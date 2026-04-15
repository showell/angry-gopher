# Claude issues

Auto-curated backlog of things Steve has asked Claude to do. Each
issue is one file with frontmatter + markdown body. Claude rebuilds
these files whenever status changes or the user asks for a refresh.

## File format

```
---
id: <int>
title: <short title>
source: <dm msg=N | wiki c-slug | ...>
status: open | in-progress | done
created: <RFC3339 timestamp>
updated: <RFC3339 timestamp>
---

## What Steve said
> (quoted DM / wiki comment)

## Status
(what's happening right now)

## Plan
(bullets — what Claude intends to do)

## Log
- <timestamp>  <line>
```

## Routes

- `/gopher/claude-issues` — index (title, status, updated)
- `/gopher/claude-issues/<id>` — detail (rendered markdown)

Every DM Claude sends should link to the relevant issue page so Steve
can click through for the full detail without scrolling the DM thread.
