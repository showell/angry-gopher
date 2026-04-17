# elm-lynrummy

Durable Elm port of the LynRummy game-state + legal-move logic.
Lives inside `angry-gopher` as of 2026-04-14 — imported wholesale
from the former standalone `~/showell_repos/elm-lynrummy/` repo,
which had no remote and was only ever a local reference instrument.

## What's here

| Directory / file | Purpose |
|---|---|
| `src/LynRummy/` | Durable Elm port of the LynRummy model: `Card`, `CardStack`, `StackType`, `BoardGeometry`, `Referee`, `Random`. Paired with the Go twin in `../` — structural parity is intentional; see `../../../tools/parity_check.py`. |
| `src/LynRummy/Tricks/` | Elm implementations of the trick library. Paired with the Go twin in `../tricks/`. |
| `tests/LynRummy/*Test.elm` | Per-module unit tests plus the cross-language `ConformanceTest.elm` which consumes fixtures generated from `../conformance/`. |
| `tests/LynRummy/Fixtures.elm` | **Generated**, do not hand-edit. Produced by `../../../tools/gen_elm_fixtures.py` from the canonical JSON fixtures. Regenerate after any fixture edit. |
| `ARCHITECTURE.md`, `OPEN_QUESTIONS.md`, `PORTING_NOTES.md`, `POSTMORTEM_PREP.md`, `CONFORMANCE_FIXTURES.md`, `TS_TO_ELM.md` | Port-specific docs preserved from the standalone repo. |
| `check.sh` | Type-checks every durable LynRummy module standalone, then runs `elm-test`. |
| `elm.json` | Elm 0.19 manifest. |

Note: the host shell (`src/Main.elm`, `src/Drag.elm`, `src/Layout.elm`,
`src/Study.elm`, `src/Style.elm`, `src/Card.elm`, `src/BoardBrowser.elm`)
and the gesture study harness (`src/Gesture/*`, `study_server.py`,
`study_logs/`, `index.html`, `elm.js`, `STUDY_RESULTS.md`) were ripped
on 2026-04-17 — the knowledge they contained was superseded. The
playable Elm game will be built fresh on top of the durable LynRummy
modules.

## Running checks

```bash
cd ~/showell_repos/angry-gopher/games/lynrummy/elm-port-docs
./check.sh
```

Type-checks every durable LynRummy module, then runs the test suite.
Greens means type-safe + tests pass.

## Regenerating fixtures

After editing any JSON under `../conformance/`:

```bash
python3 ~/showell_repos/angry-gopher/tools/gen_elm_fixtures.py
```

This rewrites `tests/LynRummy/Fixtures.elm`. Commit both the JSON
changes and the regenerated file together.

## Status

- **Durable model code:** production-ready, 2,659 lines with 2,398
  lines of tests. Cross-verified against the Go twin via 13 shared
  conformance fixtures.
- **Playable game:** not yet built; upcoming work will stand a fresh
  host shell on top of these modules (see Angry Cat's TS game as
  the porting reference).

## Why it lives inside `angry-gopher`

The former standalone repo had no remote and was only ever a
reference instrument. Keeping it inside `angry-gopher`:

- Pairs the Elm twin with the Go twin in the same checkout; the
  parity-check tool works without path gymnastics.
- Simplifies fixture generation (single source of truth for the
  JSON; no cross-repo coordination).
- Aligns with the broader direction that Gopher is the home of
  LynRummy-the-product.
- Matches an earlier precedent (Angry Cat was similarly absorbed).
