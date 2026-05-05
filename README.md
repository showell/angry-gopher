# Angry Gopher

**As-of:** 2026-05-04
**Confidence:** Working.
**Durability:** Architecture stable; LynRummy-specific surface
is the active work area.

A small Go server that hosts **LynRummy** (a single-human card
game, Elm client + TypeScript agent), plus a wiki/source
browser and small admin surface. Backed by SQLite.

Originally a Zulip-API-compatible chat server; the messaging
stack was ripped 2026-04-21. What stayed is what the LynRummy
product actually uses.

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
| Test running | `ops/check` and `ops/check-conformance` (run via `ops/list`) |
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
session data. The `games/lynrummy/` Go domain package —
dealer, referee, replay, scoring — retired 2026-04-28. Elm
is now the autonomous dealer + referee. The strategic brain
is the **TypeScript agent** at `games/lynrummy/ts/`:

- `engine_v2.ts` — A* solver with admissible heuristic,
  closed-list dedup, card-tracker liveness pruning. The
  canonical BFS engine.
- `verbs.ts` + `physical_plan.ts` — verb→primitive pipeline
  with hand-aware merging, small→large swaps, and inline
  pre-flight (R1/R2/R3 in `games/lynrummy/ts/PHYSICAL_PLAN.md`).
- `agent_player.ts` — plays full 2-hand games to deck-low.
- `transcript.ts` — writes Elm-replayable JSON straight to
  the file system (no HTTP).

All hint requests (full game + Puzzles) and the puzzle
"Let agent play" button route through the TS engine over
Elm ports + the JS glue. No Elm code path computes a hint
or runs the BFS itself.

## LynRummy

The project's main feature. **Single-human game** — solitaire
or human-vs-agent. Two-human multiplayer is out of scope.

Roles inside Gopher:

- **Dealer + Referee** — Elm-side. `Game.Dealer.dealFullGame
  seed` produces the curated opening board (KS-AS-2S-3S, the
  7s and As sets, the 234567 red-black run) plus random
  hands. `Game.Referee` validates turn completion.
- **Agent (autonomous play)** — `games/lynrummy/ts/`. The TS
  agent plays full 2-hand games offline and writes the
  result as a JSON transcript Elm can replay. See
  `games/lynrummy/ts/README.md` for the modules.
- **Hint surface** — the TS engine. Both surfaces (full game
  + Puzzles) route through `hand_play.ts:findPlay` over Elm
  ports + a JS glue (`engine_glue.js`).
- **Session storage** — Elm POSTs each full-game action to
  `/gopher/lynrummy-elm/sessions/<id>/{meta.json,actions/<seq>.json}`;
  the TS agent writes the same shape directly to the file
  system. Puzzle sessions live in a separate namespace at
  `data/lynrummy-elm/puzzle-sessions/<id>/<puzzle_name>/...`
  with their own id counter; actions post to
  `/gopher/puzzles/sessions/<id>/<puzzle_name>/action`. Files
  land under `games/lynrummy/data/`, source-controlled.

The Elm client lives at `games/lynrummy/elm/` and is served
via `/gopher/lynrummy-elm/`. The TS agent lives at
`games/lynrummy/ts/`.

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
ops/check              # full preflight: conformance + Go build + Python tests
ops/check-conformance  # conformance gate only (fixturegen + TS + Elm)
```

Do not hand-compose `go test ./...` or `elm make` calls — the ops
scripts handle sequencing, prerequisites, and cross-language
consistency checks that bare commands silently skip.
