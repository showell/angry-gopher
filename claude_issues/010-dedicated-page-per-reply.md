---
id: 10
title: REQUIREMENT — dedicated detail page per Claude reply
source: dm msg=40
status: done
created: 2026-04-15T16:46
updated: 2026-04-15T17:07
---

## What Steve said

> Once you see this message, please prioritize this over other ISSUEs. (for context, we have proven that we can live-chat) Send a heartbeat once you are up. But for the actual reply, I want each reply to have a fully dedicated page for it. I see the link and I can click to see a very detailed and organized page with a status update.

## Status

Building now. Seeded 10 issue files (including this one). Views pending — next step is `views/claude_issues.go` with index + detail handlers, then `/gopher/claude-issues` route.

## Plan

- `claude_issues/*.md` — one markdown file per issue with frontmatter (this is the storage)
- `HandleClaudeIssues` — index page listing all issues by status
- `/gopher/claude-issues/<id>` — detail page rendering the markdown
- Landing link in top nav next to 📝 Claude log
- Claude appends `· http://localhost:9000/gopher/claude-issues/<id>` to every DM that relates to an issue

## Log

- 2026-04-15T16:46  Raised — highest priority
- 2026-04-15T16:48  Issue seed files created; view code next
