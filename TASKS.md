# Task Queue

## High Priority

- [x] Advanced search — trigram FTS5, substring matching, combined filters
- [x] Linkifiers — #123, AG#123, commit hashes auto-link to GitHub
- [ ] LynRummy MPA — solitaire puzzle playable in CRUD app, no login, HTML+CSS cards, form-based moves
- [ ] Search autocomplete — debounced as-you-type results in HTML view
- [ ] Clean up all tsc errors in Angry Cat

## Normal Priority

- [x] Persist buddies in the database — server API done, Angry Cat wired up
- [x] Add server metadata DB tables — generation tracking, user sessions, ops dashboard
- [ ] Angry Cat Gopher fetch strategy — use search API + hydration instead of Zulip batches
- [ ] GitHub linkifiers in Angry Cat (part of first-class GH integration)

## Low Priority — Angry Gopher

- [ ] Enforce user name/email uniqueness to avoid confusion (e.g. duplicate bot users)
- [x] Live events via SSE — new messages appear without page reload
- [ ] FTS index backfill in import tool
- [ ] CRUD page help text and marketing copy refinement

## Low Priority — Angry Cat

- [ ] Clean up async/await usage — refine policy and make it consistent across the codebase

## Low Priority — LynRummy

- [ ] Multiplayer LynRummy in CRUD — turn-based via form submit, SSE for turn notifications
- [ ] Game replay scrubber — render events up to move N
- [ ] Daily puzzle feature
