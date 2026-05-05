# Angry Gopher

A small Go server that hosts **LynRummy** (a single-human
card game, Elm client + TypeScript agent), plus a wiki /
source browser and small admin surface. Backed by SQLite.

## Quick start

```bash
bash ops/start        # Gopher 9000 + Angry Cat 8000
```

Always use `ops/start`; do not invent ad-hoc `go run` /
`nohup ./gopher-server` invocations. The script kills any
process on 9000/8000, rebuilds the Go binary, recompiles
the Elm clients, and waits until both ports respond before
exiting.

Prod DB at `~/AngryGopher/prod/gopher.db`.

## Where to find what

| Looking for… | Read |
|---|---|
| LynRummy game (in browser) | http://localhost:9000/gopher/lynrummy-elm/ |
| LynRummy docs (top of tree) | [`games/lynrummy/README.md`](games/lynrummy/README.md) |
| Cross-language bridge paradigm | [`BRIDGES.md`](BRIDGES.md) |
| Working-vocabulary glossary | [`GLOSSARY.md`](GLOSSARY.md) |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

Per-file domain knowledge lives in module top-of-file
docstrings/comments and the subsystem READMEs. Commit
history is the authoritative design-decision record.

## Packages

| Package | Role |
|---|---|
| `auth` | HTTP Basic auth |
| `schema` | Schema for the seeded `users` table |
| `views` | HTTP handlers: HTML pages + LynRummy session-data file storage |

The Go server is dumb URL-keyed file storage for LynRummy
session data. The strategic brain is the **TypeScript
agent** at `games/lynrummy/ts/`; the Elm client at
`games/lynrummy/elm/` is the autonomous dealer + referee +
UI.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|---|---|
| `/gopher/` | Landing page |
| `/gopher/game-lobby` | Games launch pad (LynRummy) |
| `/gopher/lynrummy-elm/` | Elm LynRummy client |
| `/gopher/puzzles/` | Curated puzzle gallery |
| `/gopher/wiki/` | Wiki viewer over repo source |
| `/gopher/docs/` | Markdown essay viewer |
| `/gopher/claude/` | Pointer-out to claude-collab (port 9100) |
| `/gopher/tour` | All CRUD pages |

## Ops & testing

```
ops/start              Start Gopher (9000) + Angry Cat (8000)
ops/list               List ops commands
ops/check              Full preflight (conformance + Go build)
ops/check-conformance  Conformance gate (fixturegen + TS + Elm)
```

Do not hand-compose `go test ./...` or `elm make` calls — the
ops scripts handle sequencing, prerequisites, and
cross-language consistency checks that bare commands silently
skip.

## Operational notes

- **Data lives outside code.** DB and uploads under
  `~/AngryGopher/prod/`. The source tree is freely rm-able
  without affecting data, and vice versa.
- **No migrations.** Schema in `schema/schema.go` is the
  single source of truth. On schema change: back up the
  DB, apply the diff by hand (ALTER TABLE) or re-seed,
  deploy new code.
