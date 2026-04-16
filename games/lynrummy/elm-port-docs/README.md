# elm-lynrummy

Elm code for LynRummy. Lives inside `angry-gopher` as of
2026-04-14 — imported wholesale from the former standalone
`~/showell_repos/elm-lynrummy/` repo, which had no remote and was
only ever a local study instrument.

## What's here

| Directory / file | Purpose |
|---|---|
| `src/LynRummy/` | Durable Elm port of the LynRummy model: `Card`, `CardStack`, `StackType`, `BoardGeometry`, `Referee`, `Random`. Paired with the Go twin in `../lynrummy/` — structural parity is intentional; see `../tools/parity_check.py`. |
| `src/Gesture/` | Behavior-study gesture modules (`SingleCardDrop`, `StackMerge`, `InjectCard`, `MoveStack`, `IntegratedPlay`). Each type-checks standalone via `check.sh`. |
| `src/{Main,Drag,Layout,Study,Style,Card,BoardBrowser}.elm` | The local study harness that Steve runs via `study_server.py` + `index.html` for UI experiments. Not wired into Gopher's HTTP surface yet. |
| `tests/LynRummy/*Test.elm` | Per-module unit tests plus the cross-language `ConformanceTest.elm` which consumes fixtures generated from `../lynrummy/conformance/`. |
| `tests/LynRummy/Fixtures.elm` | **Generated**, do not hand-edit. Produced by `../tools/gen_elm_fixtures.py` from the canonical JSON fixtures. Regenerate after any fixture edit. |
| `TS_TO_ELM.md` | Language-pair handbook for the TS → Elm port. Meta-methodology cheat sheet moved to `../agent_collab/PORTING_CHEAT_SHEET.md`. |
| `ARCHITECTURE.md`, `OPEN_QUESTIONS.md`, `PORTING_NOTES.md`, `POSTMORTEM_PREP.md`, `STUDY_RESULTS.md`, `CONFORMANCE_FIXTURES.md` | Port-specific docs preserved from the standalone repo. |
| `study_logs/*.jsonl` | Captured behavior-study events from the Gesture work. |
| `check.sh` | Type-checks `Main` + every standalone gesture + every durable LynRummy module, then runs `elm-test`. |
| `elm.json` | Elm 0.19 manifest. |
| `elm.js`, `index.html` | Study harness build artifact + host page. |

## Running checks

```bash
cd ~/showell_repos/angry-gopher/elm-lynrummy
./check.sh
```

Builds every module that `Main` imports plus every standalone
gesture and LynRummy module, then runs the test suite. Greens
means type-safe + tests pass.

## Regenerating fixtures

After editing any JSON under `../lynrummy/conformance/`:

```bash
python3 ~/showell_repos/angry-gopher/tools/gen_elm_fixtures.py
```

This rewrites `tests/LynRummy/Fixtures.elm`. Commit both the JSON
changes and the regenerated file together.

## Status

- **Durable model code:** production-ready, 2,659 lines with 2,398
  lines of tests. Cross-verified against the Go twin via 13 shared
  conformance fixtures.
- **Gesture prototypes:** type-check clean; not in any user-facing
  product.
- **Study harness:** runs locally via `python3 study_server.py`
  (don't use in production).
- **Not yet live:** nothing in this directory is served by Gopher
  to real users. The `UI engine = Elm` decision commits to this
  being the default for new Gopher UI; wiring it in is future work.

## Why it lives inside `angry-gopher`

The former standalone repo had no remote and was only ever a
study/reference instrument. Keeping it inside `angry-gopher`:

- Pairs the Elm twin with the Go twin in the same checkout; the
  parity-check tool works without path gymnastics.
- Simplifies fixture generation (single source of truth for the
  JSON; no cross-repo coordination).
- Aligns with the broader direction that Gopher is the home of
  LynRummy-the-product (see `../TASKS.md`).
- Matches an earlier precedent (Angry Cat was similarly absorbed).

Move was intentionally hacky — the top-level placement and
build-tool paths can be revisited once we actually serve Elm from
Gopher.
