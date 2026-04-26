# BFS Solver — Python ↔ Elm Alignment Report

As of 2026-04-26. Covers `bfs_solver.py`, `beginner.py`,
`verbs.py`, `agent_prelude.py` (Python) and the `Game.Agent.*`
modules (Elm). Read-only inventory; no refactor proposed.

The Elm port (April 2026) was structured into seven small
modules. Python's BFS code grew incrementally and mostly lives
in `bfs_solver.py` (1048 lines), with primitives like
`classify`, `partial_ok`, `neighbors`, and the five
`_can_*_kind` functions still living in `beginner.py` (a
legacy planner not on the BFS path otherwise).

---

## Section 1 — Naming alignment

Three columns: the Python name, the camelCase form (the
mechanical equivalent), and whether Elm has the same concept
under that name.

Legend:
- ✓ — same concept, same name (camelCased equivalent)
- ≠ — same concept, DIFFERENT Elm name
- — — no Elm equivalent
- (n/a) — Elm-only or Python-only by design

### `bfs_solver.py`

| Python                       | camelCase equivalent         | Elm status                                                                  |
| ---                          | ---                          | ---                                                                         |
| `classify` (re-exported)     | `classify`                   | ✓ `Enumerator.classify` (private; returns `Kind`)                           |
| `partial_ok` (re-exported)   | `partialOk`                  | ≠ `Cards.isPartialOk` (renamed with `is` prefix per Elm idiom)              |
| `neighbors` (re-exported)    | `neighbors`                  | ✓ `Cards.neighbors`                                                         |
| `label_d` (re-exported)      | `labelD`                     | ≠ `Move.cardLabel` (no `_d` suffix; deck handling moved into the function)  |
| `_stack_label`               | `stackLabel`                 | ≠ `Move.stackStr` (different name)                                          |
| `state_sig`                  | `stateSig`                   | ≠ `Bfs.signature` (renamed; takes `FocusedState` not 4 args)                |
| `trouble_count`              | `troubleCount`               | ✓ `Buckets.troubleCount`                                                    |
| `is_victory`                 | `isVictory`                  | ✓ `Buckets.isVictory`                                                       |
| `_without`                   | `without`                    | ≠ `Enumerator.withoutAt` (uses Elm-typical `…At` suffix)                    |
| `_remove_absorber`           | `removeAbsorber`             | ✓ `Enumerator.removeAbsorber`                                               |
| `_graduate`                  | `graduate`                   | ✓ `Enumerator.graduate`                                                     |
| `_completion_inventory`      | `completionInventory`        | ✓ `Enumerator.completionInventory`                                          |
| `_completion_shapes`         | `completionShapes`           | ✓ `Enumerator.completionShapes`                                             |
| `_has_doomed_third`          | `hasDoomedThird`             | ✓ `Enumerator.hasDoomedThird`                                               |
| `_admissible_partial`        | `admissiblePartial`          | ✓ `Enumerator.admissiblePartial`                                            |
| `_extract_pieces`            | `extractPieces`              | ✓ `Enumerator.extractPieces`                                                |
| `_do_extract`                | `doExtract`                  | — (Elm folds this inline at each call site; no standalone function)         |
| `_verb_for`                  | `verbFor`                    | ✓ `Enumerator.verbFor`                                                      |
| `_extractable_index`         | `extractableIndex`           | ✓ `Enumerator.extractableIndex`                                             |
| `enumerate_moves`            | `enumerateMoves`             | ✓ `Enumerator.enumerateMoves`                                               |
| inner `_splice_halves`       | `spliceHalves`               | — (Elm inlines into `spliceMoves`; no standalone fn)                        |
| inner `_splice_legal`        | `spliceLegal`                | — (same)                                                                    |
| `narrate`                    | `narrate`                    | — (no Elm equivalent yet; Python-only)                                      |
| `hint`                       | `hint`                       | — (no Elm equivalent yet; Python-only)                                      |
| `_group_kind_phrase`         | `groupKindPhrase`            | — (Python-only, supports `narrate`/`hint`)                                  |
| `_partial_kind_phrase`       | `partialKindPhrase`          | — (same)                                                                    |
| `_run_kind_phrase`           | `runKindPhrase`              | — (same)                                                                    |
| `describe_move`              | `describeMove`               | ≠ `Move.describe` (lives on the move type, not on a desc dict)              |
| `_move_touches_focus`        | `moveTouchesFocus`           | ✓ `Enumerator.moveTouchesFocus`                                             |
| `_update_lineage`            | `updateLineage`              | ✓ `Enumerator.updateLineage`                                                |
| `_enumerate_focused`         | `enumerateFocused`           | ✓ `Enumerator.enumerateFocused`                                             |
| `_initial_lineage`           | `initialLineage`             | ✓ `Enumerator.initialLineage`                                               |
| `bfs_with_cap`               | `bfsWithCap`                 | ✓ `Bfs.bfsWithCap`                                                          |
| `solve`                      | `solve`                      | ✓ `Bfs.solve` (Elm signature differs: takes `Buckets`, no board partition) |
| `solve_state`                | `solveState`                 | — (Elm has `solveWithCap` instead)                                          |
| `solve_state_with_descs`     | `solveStateWithDescs`        | — (Elm's `solve` returns `Maybe Plan` directly, `Plan = List Move`)         |
| module flag `_FOCUS_ENABLED` | `focusEnabled`               | — (Elm has no analysis-mode bypass yet)                                     |

### `beginner.py` (the BFS reaches into this for primitives)

These six are the load-bearing imports the BFS relies on,
even though `beginner.py` is otherwise a separate legacy
planner.

| Python (BFS-load-bearing)    | camelCase                | Elm status                                                                  |
| ---                          | ---                      | ---                                                                         |
| `RANKS` constant             | `ranks`                  | — (Elm uses `Game.Card.valueStr` instead)                                   |
| `SUITS` constant             | `suits`                  | — (Elm uses `Game.Card.allSuits`)                                           |
| `RED` constant               | `red`                    | — (Elm uses `Game.Card.suitColor`)                                          |
| `card`                       | `card`                   | — (label-parser; Elm uses typed `Card` constructors directly)               |
| `label`                      | `label`                  | — (Elm: `Move.cardLabel`)                                                   |
| `label_d`                    | `labelD`                 | ≠ `Move.cardLabel` (single-purpose; Elm always emits deck suffix)           |
| `_succ`                      | `succ`                   | ≠ `Game.StackType.successor`                                                |
| `_color`                     | `color`                  | ≠ `Game.Card.cardColor` / `suitColor`                                       |
| `classify`                   | `classify`               | ≠ `Game.StackType.getStackType` + `Cards.isLegalStack` wrapper              |
| `partial_ok`                 | `partialOk`              | ≠ `Cards.isPartialOk`                                                       |
| `neighbors`                  | `neighbors`              | ✓ `Cards.neighbors`                                                         |
| `almost_neighbors`           | `almostNeighbors`        | — (Python-only; not on the BFS path)                                        |
| `_can_peel_kind`             | `canPeelKind`            | ≠ `Enumerator.canPeel` (no `…Kind` suffix)                                  |
| `_can_pluck_kind`            | `canPluckKind`           | ≠ `Enumerator.canPluck`                                                     |
| `_can_yank_kind`             | `canYankKind`            | ≠ `Enumerator.canYank`                                                      |
| `_can_steal_kind`            | `canStealKind`           | ≠ `Enumerator.canSteal`                                                     |
| `_can_split_out_kind`        | `canSplitOutKind`        | ≠ `Enumerator.canSplitOut`                                                  |
| `trouble`                    | `trouble`                | — (board-as-list trouble extractor; legacy)                                 |
| `_do_extract` (beginner's)   | `doExtract`              | — (separate from BFS's `_do_extract`; both inline-ish in Elm)               |
| `_try_extracts`              | `tryExtracts`            | — (legacy; BFS doesn't use)                                                 |
| `beginner_plan`              | `beginnerPlan`           | — (legacy; not ported)                                                      |

Note: `bfs_solver.py` lines 39–45 re-export these via `b.X`
aliases, so the BFS pretends they're local. The aliases are
the only honest declaration of which `beginner.py` symbols
the BFS relies on.

### `verbs.py`

| Python                  | camelCase              | Elm status                                                            |
| ---                     | ---                    | ---                                                                   |
| `step_to_primitives`    | `stepToPrimitives`     | ≠ `Verbs.moveToPrimitives` (renamed: "step" → "move", richer type)    |
| `_plan_split_after`     | `planSplitAfter`       | — (Elm folds split + merge planning into per-verb helpers)            |
| `_plan_merge`           | `planMerge`            | — (Elm: stack-content lookup is at the WireAction level directly)     |
| `_isolate_card`         | `isolateCard`          | ≠ `Verbs.isolateCard` (private fn in the Elm module)                  |
| `_extract_absorb`       | `extractAbsorb`        | ≠ `Verbs.extractAbsorbPrims`                                          |
| `_free_pull`            | `freePull`             | ≠ `Verbs.freePullPrims`                                               |
| `_push`                 | `push`                 | ≠ `Verbs.pushPrims`                                                   |
| `_splice`               | `splice`               | ≠ `Verbs.splicePrims`                                                 |
| `_shift`                | `shift`                | ≠ `Verbs.shiftPrims`                                                  |

### `agent_prelude.py`

| Python                       | camelCase                    | Elm status                                          |
| ---                          | ---                          | ---                                                 |
| `find_play`                  | `findPlay`                   | — (no Elm equivalent; agent-loop is Python-only)    |
| `_finish`                    | `finish`                     | — (Python-only; stats bookkeeping)                  |
| `_find_completing_third`     | `findCompletingThird`        | — (Python-only)                                     |
| `_try_projection`            | `tryProjection`              | — (Python-only)                                     |
| `find_play_with_budget`      | `findPlayWithBudget`         | — (Python-only)                                     |
| `_PROJECTION_MAX_STATES`     | `projectionMaxStates`        | — (Python-only; module-mutable knob)                |

### Underscore-private functions that look promotable

Steve's preference: don't lean on leading-underscore privacy.
The BFS code uses it heavily but most of these underscored
functions are imported across modules (`from bfs_solver
import _admissible_partial` is happening implicitly via the
single-file design — and tests reach into `_extract_pieces`,
`_completion_inventory`, etc.). If the underscore-privacy
came off, the symbols would just be public.

Candidates to drop the underscore (loose criterion: tested
or load-bearing across files):

| Python                       | Used outside its def line                                                       |
| ---                          | ---                                                                             |
| `_stack_label`               | Yes — used 5+ times in `narrate` / `describe_move` / `hint`                     |
| `_without`                   | Yes — used in 6+ places inside `enumerate_moves`                                |
| `_remove_absorber`           | Yes — used 3 times in `enumerate_moves`                                         |
| `_graduate`                  | Yes — used 3 times                                                              |
| `_completion_inventory`      | Yes — exercised by tests in `test_bfs_enumerate.py`                             |
| `_completion_shapes`         | Yes — exercised by tests                                                        |
| `_has_doomed_third`          | Yes — exercised by tests                                                        |
| `_admissible_partial`        | Yes — used 3 times in `enumerate_moves`                                         |
| `_extract_pieces`            | Yes — exercised by tests in `test_bfs_extract.py`                               |
| `_do_extract`                | Yes — used in extract loop                                                      |
| `_verb_for`                  | Yes — used in `_extractable_index`                                              |
| `_extractable_index`         | Yes — exercised by tests                                                        |
| `_move_touches_focus`        | Yes — used in `_enumerate_focused`                                              |
| `_update_lineage`            | Yes — used in `_enumerate_focused`                                              |
| `_enumerate_focused`         | Yes — used by `bfs_with_cap`; also referenced from `analyze_focus_block.py`     |
| `_initial_lineage`           | Yes — used by `solve_state_with_descs`                                          |
| `_FOCUS_ENABLED`             | Yes — flipped from outside by `analyze_focus_block.py`                          |
| `_group_kind_phrase`         | Yes — used 3 times by `hint`                                                    |
| `_partial_kind_phrase`       | Yes — used in `hint`                                                            |
| `_run_kind_phrase`           | Yes — used in `hint`                                                            |
| `_can_*_kind` (5 functions)  | Yes — every one is used by `_verb_for` and (separately) the legacy planner      |
| `_succ`, `_color`            | Yes — used internally by `classify`, `neighbors`, `partial_ok`                  |

Likely-stay-private (truly local helpers):

- `verbs.py` — `_plan_split_after`, `_plan_merge`,
  `_isolate_card` and the per-verb `_extract_absorb` /
  `_free_pull` / `_push` / `_splice` / `_shift` helpers are
  all dispatched by the public `step_to_primitives`. These
  could plausibly stay private.
- `agent_prelude.py` — `_finish`, `_find_completing_third`,
  `_try_projection` are clearly internal.
- `bfs_solver.py` — inner `_splice_halves` / `_splice_legal`
  are nested defs; not addressable from outside anyway.

---

## Section 2 — Module organization comparison

### Elm side (canonical, per the sidecars)

| Elm module                  | What it owns                                                                                                            |
| ---                         | ---                                                                                                                     |
| `Game.Agent.Buckets`        | The 4-bucket state record + `troubleCount` + `isVictory` + `Stack` alias                                                |
| `Game.Agent.Cards`          | Pure card predicates: `isLegalStack`, `isPartialOk`, `neighbors`                                                        |
| `Game.Agent.Move`           | The `Move` sum type + per-variant `*Desc` records + `ExtractVerb` + `SourceBucket` + `Side` + `WhichEnd` + `describe`   |
| `Game.Agent.Enumerator`     | The full move generator + doomed-third filter + extractable index + verb eligibility + lineage/focus mechanics          |
| `Game.Agent.Bfs`            | BFS engine (`solve`, `solveWithCap`, `bfsWithCap`, `signature`, frontier/seen bookkeeping)                              |
| `Game.Agent.Verbs`          | `Move` → `WireAction` translator (`moveToPrimitives`)                                                                   |
| `Game.Agent.GeometryPlan`   | `WireAction` post-pass: pre-flight `MoveStack` injection where geometry would fail                                      |

### Python side (today)

| Concept                                | Currently lives in                                                                                                |
| ---                                    | ---                                                                                                               |
| 4-bucket state model                   | `bfs_solver.py` (state passed as a 4-tuple; no struct/record); helpers `state_sig`, `trouble_count`, `is_victory` |
| Card predicates: classify              | `beginner.py` `classify`, re-exported as `bfs_solver.classify`                                                    |
| Card predicates: partial_ok            | `beginner.py` `partial_ok`, re-exported                                                                           |
| Card predicates: neighbors             | `beginner.py` `neighbors`, re-exported                                                                            |
| Move desc dicts                        | `bfs_solver.py` (built inline inside `enumerate_moves` as `{"type": ..., ...}` dicts)                             |
| Move rendering                         | `bfs_solver.py` (`describe_move`, `narrate`, `hint`) + `_*_kind_phrase` helpers                                   |
| Move generator                         | `bfs_solver.py` `enumerate_moves` (320 lines)                                                                     |
| Doomed-third filter                    | `bfs_solver.py` `_completion_inventory`, `_completion_shapes`, `_has_doomed_third`, `_admissible_partial`         |
| Extractable index + verb eligibility   | `bfs_solver.py` `_extractable_index`, `_verb_for`; the `_can_*_kind` it dispatches live in `beginner.py`          |
| Bucket transitions (without/remove)    | `bfs_solver.py` `_without`, `_remove_absorber`, `_graduate`                                                       |
| Extract physics                        | `bfs_solver.py` `_extract_pieces`, `_do_extract`                                                                  |
| Focus rule + lineage                   | `bfs_solver.py` `_move_touches_focus`, `_update_lineage`, `_enumerate_focused`, `_initial_lineage`                |
| BFS engine                             | `bfs_solver.py` `bfs_with_cap`, `solve`, `solve_state`, `solve_state_with_descs`, `state_sig`                     |
| Move → primitive                       | `verbs.py` `step_to_primitives` + per-verb helpers                                                                |
| Geometry pre-flight                    | `strategy.py` `_plan_merge_stack` (NOT in `verbs.py`); imported by `verbs.py`                                     |

### Proposed Python layout that mirrors the Elm split

Suggested file names: `buckets.py`, `cards.py`, `move.py`,
`enumerator.py`, `bfs.py`. Existing `verbs.py` and
`agent_prelude.py` keep their names. Existing `geometry.py`
covers what Elm's `GeometryPlan.elm` does (mostly via
`strategy._plan_merge_stack`); a `geometry_plan.py` could be
extracted but the Elm side keeps the semantic in
`strategy.py`-equivalent territory anyway.

Each row lists what would land in the new file and where it
comes from.

#### `buckets.py`

| Symbol               | From                          |
| ---                  | ---                           |
| `state_sig`          | `bfs_solver.py:52`            |
| `trouble_count`      | `bfs_solver.py:61`            |
| `is_victory`         | `bfs_solver.py:65`            |

The actual bucket data stays as a 4-tuple (Steve's "lists are
fine" preference suggests against forcing a dataclass, but
see Section 3). The module's role is pure-function operations
on (helper, trouble, growing, complete).

#### `cards.py`

| Symbol               | From                          |
| ---                  | ---                           |
| `classify`           | `beginner.py:72`              |
| `partial_ok`         | `beginner.py:131`             |
| `neighbors`          | `beginner.py:167`             |
| `_succ` / `_color`   | `beginner.py:64` / `:68`      |
| `RANKS` / `SUITS` / `RED` constants | `beginner.py:28-30` |
| `label` / `label_d`  | `beginner.py:43` / `:48`      |

This pulls the BFS-load-bearing slice out of `beginner.py`
into its own module. `beginner.py` itself could either die
(its `beginner_plan` is no longer the production planner) or
re-import these names from `cards.py` for backward
compatibility.

#### `move.py`

| Symbol               | From                          |
| ---                  | ---                           |
| desc-dict shape constants / dataclasses | `bfs_solver.py` (inline literal dicts) |
| `describe_move`      | `bfs_solver.py:687`           |
| `narrate`            | `bfs_solver.py:550`           |
| `hint`               | `bfs_solver.py:607`           |
| `_group_kind_phrase` | `bfs_solver.py:650`           |
| `_partial_kind_phrase`| `bfs_solver.py:663`          |
| `_run_kind_phrase`   | `bfs_solver.py:676`           |
| `_stack_label`       | `bfs_solver.py:48` (top-level dup of `beginner._stack_label`) |

The Elm `Move.describe` lives next to `Move`'s data
constructors. Python could put `describe_move` / `narrate` /
`hint` here, all of which currently consume `desc` dicts.
Touch radius if these become dataclasses: see Section 3.

#### `enumerator.py`

| Symbol                       | From                                  |
| ---                          | ---                                   |
| `_without`                   | `bfs_solver.py:69`                    |
| `_remove_absorber`           | `bfs_solver.py:74`                    |
| `_graduate`                  | `bfs_solver.py:83`                    |
| `_completion_inventory`      | `bfs_solver.py:92`                    |
| `_completion_shapes`         | `bfs_solver.py:116`                   |
| `_has_doomed_third`          | `bfs_solver.py:141`                   |
| `_admissible_partial`        | `bfs_solver.py:152`                   |
| `_extract_pieces`            | `bfs_solver.py:164`                   |
| `_do_extract`                | `bfs_solver.py:201`                   |
| `_verb_for`                  | `bfs_solver.py:214`                   |
| `_extractable_index`         | `bfs_solver.py:228`                   |
| `enumerate_moves`            | `bfs_solver.py:256`                   |
| `_move_touches_focus`        | `bfs_solver.py:749`                   |
| `_update_lineage`            | `bfs_solver.py:771`                   |
| `_enumerate_focused`         | `bfs_solver.py:822`                   |
| `_initial_lineage`           | `bfs_solver.py:843`                   |
| `_FOCUS_ENABLED`             | `bfs_solver.py:819`                   |
| `_can_*_kind` (5)            | `beginner.py:295,304,308,319,327`     |

Everything the move generator needs. The five `_can_*_kind`
functions move out of `beginner.py` since they're only called
from `_verb_for` (BFS) plus `_try_extracts` (legacy beginner).

#### `bfs.py`

| Symbol                   | From                       |
| ---                      | ---                        |
| `bfs_with_cap`           | `bfs_solver.py:852`        |
| `solve`                  | `bfs_solver.py:940`        |
| `solve_state`            | `bfs_solver.py:956`        |
| `solve_state_with_descs` | `bfs_solver.py:971`        |
| `__main__` block         | `bfs_solver.py:1018-1047`  |

After this split, `bfs_solver.py` is empty (or becomes a
re-export shim for backward compatibility — see deps).

### Dependencies that would break

A clean split would have to thread the following:

- `from beginner import classify, partial_ok, neighbors,
  label_d, RED` happens at the top of `bfs_solver.py`. Each
  consumer (`buckets.py`, `cards.py`, `move.py`,
  `enumerator.py`, `bfs.py`) would import directly from
  `cards.py` instead.
- `bfs_solver._enumerate_focused` is referenced from
  `analyze_focus_block.py` and (`_FOCUS_ENABLED`) from the
  same. After the split: `from enumerator import
  enumerate_focused, FOCUS_ENABLED`.
- `verbs.py` does `import bfs_solver as bs` and uses
  `bs.classify`. After the split: `from cards import
  classify`.
- `agent_prelude.py` does `import bfs_solver as bs` for
  `bs.solve_state_with_descs`, plus `from beginner import
  classify, partial_ok`. After the split: `from bfs import
  solve_state_with_descs`; `from cards import classify,
  partial_ok`.
- Tests: `test_bfs_enumerate.py`, `test_bfs_extract.py`,
  `test_bfs_failure.py`, `test_d1_d2_sweep.py`,
  `test_dsl_conformance.py` all import from `bfs_solver`.
  Each would need its imports updated. About 30 imports
  total across the test files.
- `_FOCUS_ENABLED` flipping: `analyze_focus_block.py:` reads
  `bfs_solver._FOCUS_ENABLED`. New path: `enumerator.FOCUS_ENABLED`.
- `bfs_solver.py` still has a `__main__` CLI block that
  imports from `sqlite3` etc. Either retire this or move it
  to a new `__main__.py` next to `bfs.py`.

A `bfs_solver.py` re-export shim (one-liner imports for the
public API) lets the migration land without touching every
consumer in one shot.

---

## Section 3 — Type aliases + dataclass opportunities

### Type alias candidates (top 10)

Steve's preference: keep `list`. Type aliases below all
preserve `list` semantics.

| Alias                   | Definition                                      | Why it'd help                                                                                                                                                |
| ---                     | ---                                             | ---                                                                                                                                                          |
| `Card`                  | `tuple[int, int, int]`                          | Every cards-flavored function takes/returns this triple. `(value, suit, deck)` is opaque without the alias.                                                  |
| `Stack`                 | `list[Card]`                                    | Mirrors Elm's `Stack = List Card`. Currently every Python sig says `stacks` or `helper` with no doc on what an element is.                                   |
| `Bucket`                | `list[Stack]`                                   | The four buckets are each a `list[Stack]`; right now signatures say `helper, trouble, growing, complete` without typing.                                     |
| `BucketName`            | `Literal["trouble", "growing"]`                 | `_remove_absorber(bucket_name, ...)` uses string-typed bucket names. `Literal` tells the typer.                                                              |
| `Lineage`               | `tuple[Stack, ...]`                             | `_initial_lineage` returns this; `_update_lineage` takes/returns it. Currently anonymous.                                                                    |
| `ShapeKey`              | `tuple[int, int]`                               | The `(value, suit)` pair the doomed-third filter and `_extractable_index` key on. Elm calls it `ShapeKey`.                                                   |
| `ExtractableIndex`      | `dict[ShapeKey, list[ExtractEntry]]`            | The extractable-index return type is `{(value, suit): [(hi, ci, verb), ...]}`; mirrors Elm's `Dict ShapeKey (List ExtractEntry)`.                            |
| `ExtractEntry`          | `tuple[int, int, str]`                          | Currently 3-tuple `(hi, ci, verb)`. Elm has a `{ hi, ci, verb }` record. Either a type alias or (Section 3 below) a dataclass.                               |
| `Verb`                  | `Literal["peel", "pluck", "yank", "steal", "split_out"]` | Every `verb` parameter currently typed as `str`.                                                                                                  |
| `Side`                  | `Literal["left", "right"]`                      | `desc["side"]` fields. The Elm port uses a `Side` sum type.                                                                                                  |
| `MoveType` (bonus)      | `Literal["extract_absorb", "free_pull", "push", "splice", "shift"]` | Every `desc["type"]` check. Same idea as `Side` / `Verb`.                                                                                |

Wider arc: if every "stack" became `Stack = list[Card]` the
state 4-tuple becomes `tuple[Bucket, Bucket, Bucket, Bucket]`
or — more readably — a dataclass (next subsection).

### Dataclass opportunities

Two layers candidate for promotion.

#### Buckets (the state itself)

The state is currently passed as a positional 4-tuple
`(helper, trouble, growing, complete)` and as a 5-tuple
`(helper, trouble, growing, complete, lineage)` for the
focused state. Elm uses two records:

```elm
type alias Buckets = { helper, trouble, growing, complete }
type alias FocusedState = { buckets, lineage }
```

Touch radius (Python sites that destructure the 4-tuple):

- `bfs_solver.py:259` `helper, trouble, growing, complete = state`
- `bfs_solver.py:825` `helper, trouble, growing, complete, lineage = state` (5-tuple)
- `bfs_solver.py:874-877`, `:902-914`, `:949` (`solve`),
  `:993-1002` (`solve_state_with_descs`)
- `bfs_solver.py:52` `state_sig(helper, trouble, growing, complete)` (positional)
- `bfs_solver.py:874` `trouble_count(initial[1], initial[2])`
  (positional indexing — every call site does this)
- `agent_prelude.py:139` `initial = (helper, trouble, [], [])`
- Roughly 20 destructure-or-positional-index sites in
  `bfs_solver.py`, 1 in `agent_prelude.py`, 0 in `verbs.py`.

A `Buckets` dataclass (or `NamedTuple` if Steve wants list-y
positional access too) would make every signature
self-documenting. ~25 sites would change.

#### Per-move desc dataclasses

Five candidates, mirroring Elm's `Move.elm` records:

| Dataclass             | Fields (currently `desc[...]` keys)                                                                                                              |
| ---                   | ---                                                                                                                                              |
| `ExtractAbsorbDesc`   | `verb, source, ext_card, target_before, target_bucket_before, result, side, graduated, spawned`                                                  |
| `FreePullDesc`        | `loose, target_before, target_bucket_before, result, side, graduated`                                                                            |
| `PushDesc`            | `trouble_before, target_before, result, side`                                                                                                    |
| `SpliceDesc`          | `loose, source, k, side, left_result, right_result`                                                                                              |
| `ShiftDesc`           | `source, donor, stolen, p_card, which_end, new_source, new_donor, target_before, target_bucket_before, merged, side, graduated`                  |

Touch radius for promoting desc dicts to dataclasses:

| Reader site                        | Reads                                                                                          | Approx count |
| ---                                | ---                                                                                            | ---          |
| `bfs_solver.py` `narrate`          | `desc["type"]`, `desc["loose"]`, `desc["result"]`, etc.                                        | ~25          |
| `bfs_solver.py` `hint`             | same shape                                                                                     | ~15          |
| `bfs_solver.py` `describe_move`    | same shape                                                                                     | ~30          |
| `bfs_solver.py` `_move_touches_focus` | `desc["type"]`, `desc["target_before"]`, `desc["loose"]`, `desc["trouble_before"]`          | ~7           |
| `bfs_solver.py` `_update_lineage`  | `desc["type"]`, `desc.get("graduated")`, `desc["result"]`, etc.                                | ~12          |
| `verbs.py` `step_to_primitives`    | `desc["type"]`                                                                                 | 5            |
| `verbs.py` per-verb helpers        | `desc["source"]`, `desc["ext_card"]`, `desc["loose"]`, `desc["k"]`, etc.                       | ~24          |
| `agent_game.py`                    | `desc[...]`                                                                                    | 2            |
| `analyze_focus_block.py`           | `desc[...]`                                                                                    | 8            |
| **Subtotal `desc[`-style reads**   |                                                                                                | **~121**     |

Plus 22 occurrences of `desc["type"]` specifically (the
dispatch). A dataclass migration would replace those with
isinstance checks or a `match` statement. The ~12 emit sites
inside `enumerate_moves` (literal `{"type": "...", ...}`
dicts at lines 307, 349, 442, 491, 516, 540) become 12
constructor calls.

Total move-desc-touch surface: ~133 sites in core code, plus
test files (`test_bfs_enumerate.py`, `test_bfs_extract.py`,
`test_dsl_conformance.py` all read desc keys).

A dataclass migration is the largest single change in this
report. Smallest version: keep dict shape, just add
`TypedDict` per move type so type checkers can see the
fields; zero runtime change, but only catches typos.

### Numeric summary

- **Naming misalignments flagged:** 24 (`≠` rows in Section
  1 across all four Python files).
- **Python functions with no Elm equivalent:** ~25 (the `—`
  rows, includes `narrate` / `hint` / agent_prelude / legacy
  beginner).
- **Underscore-private functions that look promotable:** ~22
  (Section 1 final table).
- **Proposed module splits:** 5 new files (`buckets.py`,
  `cards.py`, `move.py`, `enumerator.py`, `bfs.py`); 2 keep
  their names (`verbs.py`, `agent_prelude.py`).
- **Type-alias candidates:** 11.
- **Dataclass candidates:** 1 for `Buckets`/`FocusedState`,
  5 for `*Desc` (one per move type). Total ~133 sites would
  touch if `*Desc` dataclasses land.
