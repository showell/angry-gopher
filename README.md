# Angry Gopher

**As-of:** 2026-04-22
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
| `games/lynrummy` | LynRummy: dealer, referee, replay, tricks, scoring |
| `games/lynrummy/tricks` | Seven trick recognizers + hint priority |
| `schema` | Single source of truth for all DB tables |
| `views` | HTML pages (server-rendered) |

## LynRummy

The project's main feature. Three roles inside Gopher:

- **Dealer** (`lynrummy` package) — canned opening boards + canned
  two-player hands. Per-session seed makes replays reproducible.
- **Referee** (`lynrummy` package) — validates turn completion via
  protocol/geometry/semantics/inventory checks. Stateless.
- **Hint system** (`lynrummy/tricks` package) — seven trick
  recognizers walked in simplest-first priority order; each
  firing trick yields one representative suggestion.

The Elm client lives at `games/lynrummy/elm/` and is
served via `/gopher/lynrummy-elm/`. A Python agent-side client
is at `games/lynrummy/python/`.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|---|---|
| `/gopher/` | Landing page |
| `/gopher/game-lobby` | Games launch pad (LynRummy) |
| `/gopher/lynrummy-elm/` | Elm LynRummy client |
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
