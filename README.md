# Angry Gopher

**As-of:** 2026-04-26
**Confidence:** Working.
**Durability:** Architecture stable; LynRummy-specific surface
is the active work area.

A small Go server that hosts **LynRummy** (a two-player card
game, Elm client), plus a wiki/source browser and small admin
surface. Backed by SQLite.

Originally a Zulip-API-compatible chat server; the messaging
stack (events, users, DMs, channels, reactions, search) was
ripped 2026-04-21. What stayed is what the LynRummy product
actually uses.

## Quick start

```bash
bash ops/start        # Gopher 9000 + Angry Cat 8000
```

Always use `ops/start`; do not invent ad-hoc `go run` /
`nohup ./gopher-server` invocations. The script kills any
process on 9000/8000 first, rebuilds the Go binary, recompiles
the Elm clients, regenerates the puzzles catalog, and waits
until both ports respond before exiting.

Prod DB at `~/AngryGopher/prod/gopher.db`.

## Where to find what

| Looking for… | Read |
|---|---|
| LynRummy game (Elm client) | http://localhost:9000/gopher/lynrummy-elm/ |
| LynRummy Go subsystem + architecture | [`games/lynrummy/README.md`](games/lynrummy/README.md) → [`ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md) |
| Deploy / modes / backups | `DEPLOYMENT.md` |
| Test running, timings, lessons | `TESTING.md` |
| Module-label index | `LABELS.md` (generated) |
| Pattern catalog / design vocabulary | `GLOSSARY.md`, `BRIDGES.md` |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

Per-file domain knowledge lives in module top-of-file
docstrings/comments and the subsystem READMEs. The legacy
`.claude` sidecar system was retired 2026-04-28; commit
messages are the authoritative history record.

## Packages

| Package | Role |
|---|---|
| `auth` | HTTP Basic auth |
| `schema` | Schema for the (now tiny) `users` table |
| `views` | HTTP handlers: HTML pages + LynRummy session-data file storage |

The Go server is dumb URL-keyed file storage for LynRummy
session data (LEAN_PASS phase 2, 2026-04-28). The
`games/lynrummy/` Go domain package — dealer, referee,
replay, scoring, all of it — was retired in the same milestone.
Elm is now the autonomous dealer + referee. Two strategic
engines live on the Python side:

- `games/lynrummy/python/bfs.py` (plus `enumerator.py`,
  `move.py`, `buckets.py`, `cards.py`) — the four-bucket
  BFS planner. Strategic brain. Milestone 2026-04-25;
  focus rule + SPLIT_OUT verb landed 2026-04-26; module
  split landed 2026-04-26 afternoon.
- `games/lynrummy/python/strategy.py` — older trick
  recognizers + hint priority (legacy, retiring).

Elm has a near-complete port of the BFS planner under
`games/lynrummy/elm/src/Game/Agent/` (Buckets, Move,
Enumerator, Bfs, Verbs, GeometryPlan), plus the
locked-down rule layer at `Game/Rules/` (`Card`,
`StackType`). All five
extract verbs, the doomed-third filters (merge-time +
state-level), and the focus rule + lineage tracking are
live as of 2026-04-26. Remaining drift: loop inversion
via `_extractable_index`, `narrate` / `hint` renderers,
and the `solve_state_with_descs` diagnostics callback.
See `games/lynrummy/elm/README.md` for the current
drift detail. Elm also still hosts the older trick
engine at `games/lynrummy/elm/src/Game/Strategy/`,
retiring alongside Python's `strategy.py`.

## LynRummy

The project's main feature. **Single-human game** — solitaire
or human-vs-agent (the Elm BFS planner can play as the
opponent). Two-human multiplayer is out of scope (product
decision 2026-04-28: scheduling friction outweighs the value
once Elm has agent capability built in).

Roles inside Gopher:

- **Dealer + Referee** — Elm-side. `Game.Dealer.dealFullGame
  seed` produces the curated opening board (KS-AS-2S-3S, the
  7s and As sets, the 234567 red-black run) plus random hands.
  `Game.Referee` validates turn completion. Both lived in Go
  until 2026-04-28; retired with the rest of the Go domain
  package.
- **Strategy layer** (client-side) — Python-side current brain
  is the four-bucket BFS planner
  (`games/lynrummy/python/{bfs,enumerator,move,buckets,cards}.py`).
  Elm has the planner ported at
  `games/lynrummy/elm/src/Game/Agent/` and uses it for puzzle
  hints; full-game UI still uses the older trick engine
  (`Game.Strategy.Hint`) pending a swap-in. Server has no
  opinion on which plays are smart.
- **Session storage** — Elm POSTs the dealt initial state +
  per-action wire envelopes to
  `/gopher/lynrummy-elm/sessions/<id>/{meta.json,actions/<seq>.json}`.
  Files land under `games/lynrummy/data/`, all source-controlled.

The Elm client lives at `games/lynrummy/elm/` and is served via
`/gopher/lynrummy-elm/`. Python tools live at
`games/lynrummy/python/`.

**Puzzles** (`games/lynrummy/puzzles/`) is the study
instrument: a gallery of curated puzzles served at
`/gopher/puzzles/`. The Elm Puzzles app embeds one
`Main.Play` component per puzzle panel — proving the "Elm
components should be easy to embed" design goal. Puzzle seeds
live at `games/lynrummy/conformance/mined_seeds.json`.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|---|---|
| `/gopher/` | Landing page |
| `/gopher/game-lobby` | Games launch pad (LynRummy) |
| `/gopher/lynrummy-elm/` | Elm LynRummy client |
| `/gopher/puzzles/` | Curated puzzle gallery (study instrument) |
| `/gopher/wiki/` | Wiki viewer over repo source |
| `/gopher/docs/` | Markdown essay viewer |
| `/gopher/claude/` | Pointer-out to claude-collab (port 9100) |
| `/gopher/tour` | All CRUD pages |

## Ops

```
ops/start         Start Gopher (9000) + Angry Cat (8000)
ops/list          List ops commands
ops/check         Run all tests across the repo
```

## Testing

```bash
go test ./...          # all tests
go test ./games/...    # game logic only
```

See `TESTING.md` for more.
