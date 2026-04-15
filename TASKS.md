# Task Queue

**As-of:** 2026-04-15
**Confidence:** Tentative — queue of intent, not a stable record; individual entries reflect whatever was on our minds at write time.
**Durability:** Task queue; individual items churn. Expect continuous add/remove.

## Immediately after current 8h tricks-port

- [ ] **Replace fixture system with code-generation from a mainstream language.** Steve will elaborate on motivation/design. Decision recorded 2026-04-14 during the TrickBag Go-port session. Current system: hand-written JSON in `lynrummy/conformance/`, consumed by typed loaders in Go / Elm / TS. Next evolution: generate fixtures programmatically from one source of truth rather than maintaining JSON by hand.

## High Priority

- [x] Advanced search — trigram FTS5, substring matching, combined filters
- [ ] LynRummy MPA — solitaire puzzle playable in CRUD app, no login, HTML+CSS cards, form-based moves
- [ ] Search autocomplete — debounced as-you-type results in HTML view
- [ ] Clean up all tsc errors in Angry Cat

## Normal Priority

- [ ] Angry Cat Gopher fetch strategy — use search API + hydration instead of Zulip batches

## Low Priority — Angry Gopher

- [ ] Enforce user name/email uniqueness to avoid confusion (e.g. duplicate bot users)
- [x] Live events via SSE — new messages appear without page reload
- [ ] FTS index backfill in import tool
- [ ] CRUD page help text and marketing copy refinement

## Low Priority — Angry Cat

- [ ] Clean up async/await usage — refine policy and make it consistent across the codebase
- [x] Add "determinism in tests" principle to `src/tests/TESTING.md` — written up as the "Tests own all their inputs" section, with concrete slots (PRNG seeds, clocks, iteration order, UUIDs, network) and the mulberry32-port-as-cross-language-fixture example.

## Low Priority — LynRummy

- [ ] Multiplayer LynRummy in CRUD — turn-based via form submit, SSE for turn notifications
- [ ] Game replay scrubber — render events up to move N
- [ ] Daily puzzle feature
- [ ] Scoring reward for tidying board from CROWDED to CLEANLY_SPACED
- [ ] Hint coverage: craft SIX_TO_FOUR fixture (needs two 3-sets of same value across D1/D2; helpers now support D2 syntax)
- [ ] Hint coverage: decide whether REARRANGE_PLAY should be wired into get_hint as an opt-in expert level, or removed entirely (currently dormant per STRATEGY.md)
- [ ] Hint system: narrator strings live inside HintLevel enum values; if we ever want i18n or richer hints, split narrator into a separate table (see insights/hint_system_process.md)
- [ ] UI friction on multi-step tricks — Steve's SWAP solve used 7 UI ops for a one-gesture table move; explore drag-and-replace primitive (see memory: project_lynrummy_ui_friction.md) — queued as next session's topic
- [ ] Retroactive trick detection — after a human drag-and-drop move lands, re-run the TrickBag against the pre-move state and tag the resulting play with the matching trick_id. Surfaces unconscious trick usage in replay analytics.
- [ ] Hint-driven moves — when user clicks Hint + a "Play it" button, auto-execute the suggested play and POST /plays with that trick_id. Makes the UI an actor in the plugin system instead of just a displayer.
