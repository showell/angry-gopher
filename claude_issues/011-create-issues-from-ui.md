---
id: 11
title: Create new issues from the issues page (UI)
source: dm msg=51
status: done
created: 2026-04-15T16:58
updated: 2026-04-15T17:02
---

## What Steve said

> ISSUE: Need a way to create new issues from the issues page. GOOD NEWS! The view page is working and looks good.

## Status

**Done 2026-04-15T17:02.** Collapsible "➕ File a new issue" form at the top of `/gopher/claude-issues` with title / source / body. POST writes `claude_issues/NNN-slug.md` with auto-assigned id and redirects to the new detail page.

## Plan

- Add a "New issue" form at the top of `/gopher/claude-issues` (title, source, initial body)
- POST handler writes a new `NNN-slug.md` file with an auto-assigned next ID
- Redirect to the new detail page
- Consider also: a "file this as an issue" button on each DM row, pre-filling title + source

## Log

- 2026-04-15T16:58  Raised by Steve; filed
