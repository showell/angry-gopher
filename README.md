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
bash ops/start        # prod: Gopher 9000 + Angry Cat 8000
bash ops/start_demo   # demo: disposable DB, seeded users
```

Prod DB at `~/AngryGopher/prod/gopher.db`.

## Where to find what

| Looking for… | Read |
|---|---|
| LynRummy game (Elm client) | http://localhost:9000/gopher/lynrummy-elm/ |
| LynRummy Go subsystem + architecture | [`games/lynrummy/README.md`](games/lynrummy/README.md) → [`ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md) |
| LynRummy wire format | [`games/lynrummy/WIRE.md`](games/lynrummy/WIRE.md) |
| Deploy / modes / backups | `DEPLOYMENT.md` |
| Test running, timings, lessons | `TESTING.md` |
| Per-file domain knowledge | `<file>.claude` sidecar next to any `.go` file |
| Module-label index | `LABELS.md` (generated) |
| Pattern catalog / design vocabulary | `GLOSSARY.md`, `BRIDGES.md` |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

**Every `.go` file has a sibling `.claude` sidecar** carrying
its maturity label + domain knowledge. When landing in
unfamiliar code, read the sidecar first.

## Packages

| Package | Role |
|---|---|
| `auth` | HTTP Basic auth |
| `games/lynrummy` | LynRummy: dealer, referee, replay, scoring |
| `schema` | Single source of truth for all DB tables |
| `views` | HTML pages (server-rendered) |

Strategy lives in the clients, never in Go. Go owns only
wire + referee. The Python side currently houses two
strategic engines:

- `games/lynrummy/python/bfs_solver.py` — the four-bucket BFS
  planner (current strategic brain, milestone 2026-04-25).
- `games/lynrummy/python/strategy.py` — older trick
  recognizers + hint priority (legacy, retiring).

Elm has a partial port of the BFS planner under
`games/lynrummy/elm/src/Game/Agent/` (Buckets, Cards,
Move, Enumerator, Bfs, Verbs, GeometryPlan; phases 1–5
landed). Python continued evolving (OPTIMIZE_PYTHON
filters + diagnostics, 2026-04-25/26); see
`games/lynrummy/elm/README.md` for the current Python →
Elm drift list. Elm also still hosts the older trick
engine at `games/lynrummy/elm/src/Game/Strategy/`,
retiring alongside Python's `strategy.py`.

## LynRummy

The project's main feature. Three roles inside Gopher:

- **Dealer** (`lynrummy` package) — canned opening boards + canned
  two-player hands. Per-session seed makes replays reproducible.
- **Referee** (`lynrummy` package) — validates turn completion via
  protocol/geometry/semantics/inventory checks. Stateless.
- **Strategy layer** (client-side) — Python-side current
  brain is the four-bucket BFS planner
  (`games/lynrummy/python/bfs_solver.py`). Elm has a
  partial port at `games/lynrummy/elm/src/Game/Agent/`
  with known drift on the Python optimizations side. The
  older seven-trick recognizer engine
  (`games/lynrummy/python/strategy.py`,
  `games/lynrummy/elm/src/Game/Strategy/`) is still wired
  but retiring. Server has no opinion on which plays are
  smart.

The Elm client lives at `games/lynrummy/elm/` and is
served via `/gopher/lynrummy-elm/`. A Python agent-side client
is at `games/lynrummy/python/`.

**BOARD_LAB** (`games/lynrummy/board-lab/`) is the study
instrument: a gallery of curated puzzles served at
`/gopher/board-lab/`, where a human plays inline and the
Python agent plays the same catalog via
`agent_board_lab.py`. Both sides' attempts land in
SQLite keyed by `puzzle_name`, so `study.py` can read
them side-by-side. The Elm Lab app embeds one
`Main.Play` component per puzzle panel — proving the
"Elm components should be easy to embed" design goal.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|---|---|
| `/gopher/` | Landing page |
| `/gopher/game-lobby` | Games launch pad (LynRummy) |
| `/gopher/lynrummy-elm/` | Elm LynRummy client |
| `/gopher/board-lab/` | Curated puzzle gallery (study instrument) |
| `/gopher/wiki/` | Wiki viewer over repo source |
| `/gopher/docs/` | Markdown essay viewer |
| `/gopher/code/` | Code browser |
| `/gopher/claude/` | Pointer-out to claude-collab (port 9100) |
| `/gopher/tour` | All CRUD pages |

## Ops

```
ops/start         Start prod servers (9000 + 8000)
ops/start_demo    Start demo servers with seeded data
ops/import        Import external data
ops/list          List ops commands
```

## Testing

```bash
go test ./...          # all tests
go test ./games/...    # game logic only
```

See `TESTING.md` for more.
