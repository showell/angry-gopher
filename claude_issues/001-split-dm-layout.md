---
id: 1
title: Split DM conversation into context-left / compose-right layout
source: dm msg=10
status: done
created: 2026-04-15T16:10
updated: 2026-04-15T17:06
---

## What Steve said

> I can immediately see value in having a focused page where it's basically an entire compose box on the right and context on the left. This is how Angry Cat does it, more or less.

## Status

**Done 2026-04-15T17:06.** DM conversation page is now a two-column CSS grid. Left column: scrollable thread. Right column: sticky compose at 420px wide with the enlarged textarea, status indicator, and the quick-link row from #12. Collapses to single column under 900px viewport. Body max-width bumped to 1200px on DM pages so both columns have room.

## Plan

- Convert `renderDMConversation` into a two-column CSS grid
- Left column: scrollable thread (flex-grow)
- Right column: sticky compose (the enlarged textarea we already built)
- Mobile: collapse to single column

## Log

- 2026-04-15T16:17  Acked via DM #14; asked do-now vs queue
- 2026-04-15T16:47  Reprioritized below this very feature
