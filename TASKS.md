# Task Queue

## High Priority

- [x] Advanced search — trigram FTS5, substring matching, combined filters
- [ ] Search autocomplete — debounced as-you-type results in HTML view
- [ ] Linkifiers — turn #123 into GitHub issue/PR links, affects markdown processor and search
- [ ] Clean up all tsc errors in Angry Cat

## Normal Priority

- [x] Persist buddies in the database — server API done, Angry Cat wired up
- [x] Add server metadata DB tables — generation tracking, user sessions, ops dashboard
- [ ] GitHub linkifiers in Angry Cat (part of first-class GH integration)
- [ ] Angry Cat Gopher fetch strategy — use search API + hydration instead of Zulip batches

## Low Priority — Angry Gopher

- [ ] Enforce user name/email uniqueness to avoid confusion (e.g. duplicate bot users)
- [ ] Explore mapping Zulip events to SSE/htmx for live-updating HTML views
- [ ] FTS index backfill in import tool

## Low Priority — Angry Cat

- [ ] Clean up async/await usage — refine policy and make it consistent across the codebase

## Low Priority — LynRummy

- [ ] (add LynRummy tasks here when recalled)
