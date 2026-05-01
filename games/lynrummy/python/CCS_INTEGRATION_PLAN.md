# ClassifiedCardStack — BFS integration plan

Durable plan for the next session. The standalone type + pure-function
API is landed and rock-solid (75 tests pass). This document is the
recipe for wiring it into the BFS data path.

## Where we are now (commits on master)

- `b80e8c4` — `bench_timing.py` methodology (warmup + GC-disabled +
  process_time + min-of-20). 2Sp noise band tightened from >25% to
  <6%. Both `gen_baseline_board.py` and `check_baseline_timing.py`
  use it now.
- `8a13e0b` / `b989384` / `a350180` — `classified_card_stack.py` +
  `test_classified_card_stack.py` landed across three iterations.
  Final shape: probe + custom-executor pattern with the 7-kind
  alphabet (run / rb / set / pair_run / pair_rb / pair_set / singleton).
  No `KIND_OTHER`. No method on the type does transformation work —
  all operations are module-level pure functions.

What's NOT done: integration. `bfs.py`, `enumerator.py`,
`buckets.py`, `card_neighbors.py` still operate on raw card lists +
the legacy `classify` from `rules.stack_type` (with old alphabet:
"set", "pure_run", "rb_run", "other").

## The invariant

**No invalid stacks ever reach BFS.** The boundary
(`solve_state_with_descs`) classifies every input stack via
`classify_stack`; any None classification is a caller bug and raises.
Inside BFS, every helper / trouble / growing / complete stack is one
of the 7 valid kinds. No `KIND_OTHER`.

This was empirically verified against the corpus and a BFS trace:

| scope | total | invalid |
|---|---|---|
| Corpus stacks across all conformance fixtures | 1369 | 0 |
| Yielded BFS states across 7 hot tantalizing scenarios | 8490 | 0 |

The audit script lives in the conversation history and was a one-shot
validation; not a permanent test (would just re-prove the invariant).

## Old kind alphabet → new kind alphabet

Existing `rules.stack_type.classify` returns one of:
`"set"`, `"pure_run"`, `"rb_run"`, `"other"`.

New `ClassifiedCardStack.kind` is one of:
`KIND_SET` (= `"set"`), `KIND_RUN` (= `"run"`), `KIND_RB` (= `"rb"`),
`KIND_PAIR_SET`, `KIND_PAIR_RUN`, `KIND_PAIR_RB`, `KIND_SINGLETON`.

Note the rename: `pure_run` → `run`, `rb_run` → `rb`. The integration
needs to update every site that compared against the old strings.

`cards.py` predicates (`can_peel` etc.) still use old strings — they
get replaced by `classified_card_stack.can_*` versions which already
use new strings. Once integration is done, `cards.py`'s old predicates
can be deleted (or kept temporarily as a transitional shim).

## Sites to touch (call-site inventory)

`enumerator.py` — `classify` calls at lines:
- **40**: `graduate(merged, growing, complete)` — `if classify(merged) != "other"`. Becomes `if merged.kind in (KIND_RUN, KIND_RB, KIND_SET)` once `merged` is a CCS. The graduate function itself either takes a CCS directly, or an absorb result that's already classified by the probe.
- **249**: `helper_kinds = [classify(s) for s in helper]` — becomes `[s.kind for s in helper]`. Free attribute reads.
- **410**: `if classify(new_source) != kind` — shift's source-rebuild check. Becomes a probe call (the new_source is built from `donor_idx` + a swapped card; rebuild it as a CCS via `classify_stack` once and check `.kind`).
- **462–463**: `_splice_legal(left, right)` — calls `classify` twice. Replace with `kinds_after_splice` returning Optional pair, or just call `classify_stack` on each half (both work; the probe is more honest about the data shape).
- **500**: push merge — `if classify(merged) == "other": continue`. Becomes `kind = kind_after_absorb_right(target, t.cards[0])` (or composed for length-2 trouble). Gate on `kind is None`.
- **522**: engulf merge — same pattern as push. Composed absorb_*.

The other patterns:
- `extract_pieces` (lines 121-157) — replace with dispatch: `verb = verb_for_position(stack, ci); if verb == "peel": return peel(stack, ci); ...`. Each of the five verbs returns its custom piece tuple.
- `do_extract` (lines 160-172) — wraps `extract_pieces`. Caller (the absorb / free-pull / shift loops in `enumerate_moves`) consumes the pieces. Direct CCS replacements throughout.
- `extractable_index` (line 189) — builds `(value, suit) → [(hi, ci, verb, kind)]` mapping. Verb/kind are still relevant; just feed `helper[hi].kind` instead of `helper_kinds[hi]`.
- `absorber_shapes` (line 274) — builds `(bucket, idx, target_stack, sorted_shapes, shapes_set)`. The `target_stack` becomes a CCS; the rest stays.
- `admissible_partial` (line 107-116) — gate on absorbed-result legality. Replace with the absorb probe directly (no wrapper needed).

`bfs.py` — sites:
- **74**: `from rules import classify` — drop after migration; or keep `rules.stack_type` for input validation if needed.
- **77**: `from card_neighbors import build_card_loc, is_live` — `card_neighbors.build_card_loc(buckets)` walks the buckets to assign per-card bucket tags. Update it to walk through `Buckets[CCS]` (just iterate `.cards` instead of treating the stack as a list).
- **200–201**: `solve()` partitions a flat `board` into helper/trouble. Update to classify each stack and route by kind (length 3+ legal kind → helper, otherwise → trouble).
- **224 (`_all_trouble_singletons_live`) / 251 (`_any_trouble_singleton_newly_doomed`)**: iterate buckets; check `len(t_stack) == 1`. With CCS, `len()` still works via `__len__` delegation. Or check `t_stack.kind == KIND_SINGLETON`.
- **300 (boundary in `solve_state_with_descs`)**: this is THE boundary. Convert input `Buckets` (which may arrive as raw lists from agent_prelude / fixturegen / tests) into `Buckets[CCS]` here. Raise on any None classification.

`buckets.py`:
- `state_sig(helper, trouble, growing, complete)` (line 52) — sorts stacks for memoization key. Update to sort by `.cards` (since `__iter__` is delegated, `tuple(sorted(st))` should still work — verify).
- `trouble_count` (line 61) — `sum(len(s) for s in trouble) + ...` — works as-is since `__len__` is delegated.
- `is_victory` (line 65) — `not trouble and all(len(s) >= 3 for s in growing)` — works as-is. Could tighten to `s.kind in _LEN3_KINDS`.

`card_neighbors.py`:
- `build_card_loc(buckets)` — walks each bucket's stacks. Update to use `.cards` if the stack iter shape changes (it shouldn't — CCS iter delegates).

`agent_prelude.py`, `fixturegen.py`, mining tools, tests — call solve at the boundary. They pass raw `Buckets` of lists. Either:
1. Convert at the call site (each caller does `classify_stack` per stack).
2. Have `solve_state_with_descs` accept either raw or CCS Buckets and convert internally.

Option 2 is more boundary-friendly. The conversion path is small: a helper that wraps a raw `Buckets` (4 lists of lists) into `Buckets` of `tuple[CCS, ...]` per bucket, raising on invalid stacks.

## Probe + executor mapping for each old pattern

| Old pattern | New pattern |
|---|---|
| `helper_kinds = [classify(s) for s in helper]` | `s.kind for s in helper` (attribute reads) |
| `extract_pieces(source, ci, verb, kind)` | `verb_for_position(source, ci)` then dispatch to `peel` / `pluck` / `yank` / `steal` / `split_out`. Each returns a tuple; route extracted+remnants by length and kind to helper/trouble. |
| `merged = [*target, ext_card]; if classify(merged) == "other": continue; ...; graduate(merged, ...)` | `kind = kind_after_absorb_right(target, ext_card); if kind is None: continue; merged = absorb_right(target, ext_card, kind); graduate(merged, ...)`. `graduate` consumes `merged.kind`. |
| `_splice_legal(left, right) → bool` and `_splice_halves(side, src, k, loose)` | `kinds = kinds_after_splice(stack, loose, k, side); if kinds is None: continue; left, right = splice(stack, loose, k, side, *kinds)` |
| Push: `merged = [*h, *t]; if classify(merged) == "other": continue` | For length-1 trouble (singleton): one `kind_after_absorb_right(h, t.cards[0])` + `absorb_right`. For length-2 trouble: two sequential `kind_after_absorb_*` + `absorb_*` calls (helper extends by t.cards[0] then t.cards[1]). Side='right' on both. |
| Engulf (`growing engulfs helper`): same shape | Same as push but with `growing` and `helper` swapped. |

## graduate() rewrite

Current:
```python
def graduate(merged, growing, complete):
    if classify(merged) != "other":
        return list(growing), complete + [merged], True
    return growing + [merged], list(complete), False
```

After integration:
```python
def graduate(merged, growing, complete):
    """`merged` is a ClassifiedCardStack. If kind is length-3+ legal,
    it graduates to COMPLETE; otherwise (length-2 partial) it stays
    in GROWING."""
    if merged.kind in (KIND_RUN, KIND_RB, KIND_SET):
        return list(growing), complete + [merged], True
    return growing + [merged], list(complete), False
```

## Tests / gates

After each substantive change run:
1. `python3 test_classified_card_stack.py` — 75 tests, must stay green.
2. `./check.sh` — full pytest suite, all 10 files (test_bfs_enumerate, test_dsl_conformance, etc.) must pass.
3. `python3 check_baseline_timing.py` — 81 baselines, plan correctness implicit (DSL conformance) + timing within 10% of gold.
4. `python3 bench_outer_shell.py` — plan quality must stay `better=19 same=41 worse=0`. Wall time may regress; that's expected per Steve's guidance ("slower to start, easier to profile").
5. `ops/check-conformance` (from repo root) — Elm side; only matters if any DSL fixture changes.

Steve's expectation: integration will be slower than current. We're trading wall-time temporarily for a cleaner data shape that's easier to profile. Once landed, profile-driven optimization can target the real hotspots.

## Order of operations

Suggested sequence — each step compiles + passes tests at the end:

1. **Boundary conversion helper.** Add a function (likely in `buckets.py` or a new `bucket_factory.py`) that takes a raw `Buckets` of lists-of-lists and returns a `Buckets` of `tuple[CCS, ...]`. Raises on any None classification. Add tests.
2. **`solve_state_with_descs` boundary.** Apply the conversion at the top. Internally, BFS still operates on raw lists for now. This is the minimum thing that asserts the invariant without changing data shapes downstream. Run all gates.
3. **Convert `state_sig`, `trouble_count`, `is_victory`.** Verify they work with CCS-shaped inputs. Probably no code changes needed (container delegation handles it). Add CCS-shaped tests.
4. **Convert `enumerator.py`.** This is the big change. Replace each old pattern with the new. Be especially careful with:
   - The absorb-merge sites (extract_absorb, free_pull, shift): probe + executor.
   - The push and engulf sites: composed absorb calls.
   - The splice site: probe + executor.
   - `extract_pieces` / `do_extract`: dispatch via `verb_for_position` + the five executors.
   - `helper_kinds`: just attribute reads.
5. **Update `bfs.py`** for `_all_trouble_singletons_live`, `_any_trouble_singleton_newly_doomed`, `solve()`, and any other site iterating buckets.
6. **Update `card_neighbors.build_card_loc`** to handle CCS-shaped buckets.
7. **Update tests / agent_prelude / mining tools** at their boundaries — easiest is to use the boundary conversion helper everywhere they construct Buckets.
8. **Drop old `classify`** from `rules.stack_type` if nothing imports it anymore. Same for `cards.py` predicates.
9. **Run all gates. Refresh gold files** with the new methodology if there's been any meaningful drift. Don't refresh just for noise.

## Watchouts

- **Generator-import binding**: `bfs.py` does `from enumerator import enumerate_focused`. The bound name in `bfs.py` doesn't update if you patch `enumerator.enumerate_focused` — patch `bfs.enumerate_focused` directly. (Discovered during the audit.)
- **`Buckets` is a NamedTuple** — `Buckets(helper, trouble, growing, complete)`. The `helper` etc. fields are bucket lists. After integration these are lists of CCS (NOT tuples — the BFS does in-place-style mutations like `complete + [merged]` which expect lists; keep that shape).
- **Lineage**: the BFS focus rule (`enumerate_focused`) tracks lineage as `tuple(tuple(stack), ...)` — content-based identity. With CCS, the equivalent is `tuple(s.cards for s in lineage_stacks)` or just `tuple(s for s in lineage_stacks)` since CCS is hashable. Pick one and be consistent.
- **`move_touches_focus`** compares `tuple(desc.target_before) == focus`. `target_before` is currently `list(target)` (raw cards). With CCS, decide whether `target_before` is a CCS or stays as a card tuple for descriptor stability. Descriptors are also serialized into plan lines; raw card tuples are likely the right call for compatibility.
- **DSL conformance tests** parse fixtures and build raw `Buckets`. They route through `solve_state_with_descs`, so the boundary conversion handles them. But they ALSO call `enumerate_moves` directly in `test_bfs_enumerate.py` — those tests need to either build CCS-shaped Buckets or use the boundary conversion helper.
- **`test_dsl_conformance.py`** has a path that calls `enumerator.enumerate_moves(state)` directly. Same handling.

## Acceptance

Integration is done when:
- `./check.sh` passes (10/10 files including 75 CCS tests + 184 existing tests).
- `python3 check_baseline_timing.py` passes.
- `python3 bench_outer_shell.py` reports `better=19 same=41 worse=0` (plan quality preserved).
- Wall time may be worse — that's expected. We profile next.
- No `classify(...)` calls remain in `bfs.py` / `enumerator.py` (grep returns only docstrings and comments).
- `enumerator.py`'s `extract_pieces`, `do_extract`, `_splice_halves`, `_splice_legal`, `admissible_partial`, `graduate` either use the new probe/executor primitives or are gone.
