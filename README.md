# Angry Gopher

**As-of:** 2026-04-18
**Confidence:** Working.
**Durability:** Architecture stable; LynRummy-specific surface
is the active work area.

A small Go server that hosts **LynRummy** (a two-player card
game ported from TypeScript to Elm), hosts documentation, and
carries a lightweight Claude↔Steve collaboration layer (DMs,
wiki comments, issue tracker, essay pipeline). Backed by
SQLite.

Originally a Zulip-API-compatible chat server; Zulip compliance
was retired as a goal on 2026-04-18 along with the chat-stack
surface (channels/messages/search/flags/reactions/presence).
What stayed is what Steve + Claude actually use together.

## Quick start

```bash
bash ops/start
```

Starts Gopher on port 9000 and the Angry Cat dev server on
port 8000. Prod database at `~/AngryGopher/prod/gopher.db`.

Demo mode with seeded data:

```bash
bash ops/start_demo
```

## Where to find what

| Looking for… | Read |
|---|---|
| LynRummy game (Elm client) | http://localhost:9000/gopher/lynrummy-elm/ |
| Essays by Claude | http://localhost:9000/gopher/essays |
| Long-polling event system internals | `EVENTS.md` |
| Deploy / modes / backups | `DEPLOYMENT.md` |
| Day-to-day ops scripts | `OPERATIONS.md` |
| Test running, timings, lessons | `TESTING.md` |
| Per-file domain knowledge | `<file>.claude` sidecar next to any `.go` file |
| Module-label index | `LABELS.md` (generated) |
| LynRummy ↔ Elm port status | `games/lynrummy/ELM_TO_GO.md` |
| How Steve & Claude collaborate | `agent_collab/` |
| Pattern catalog / design vocabulary | `PATTERNS.md`, `GLOSSARY.md`, `BRIDGES.md` |

**Every `.go` file has a sibling `.claude` sidecar** carrying
its maturity label + domain knowledge. When landing in
unfamiliar code, read the sidecar first.

## Packages

| Package | Role |
|---|---|
| `auth` | HTTP Basic auth |
| `dm` | Direct-message conversations (Claude↔Steve is the main user) |
| `events` | SSE-style long-polling event system |
| `games/lynrummy` | LynRummy: dealer, referee, replay, tricks, scoring |
| `games/lynrummy/tricks` | Seven trick recognizers + hint priority |
| `games/critters` | Critter behavior studies |
| `claude_issues` | Issue tracker for Claude↔Steve work |
| `notify` | Push-notification helpers |
| `users` | User accounts |
| `schema` | Single source of truth for all DB tables |
| `respond` | JSON response helpers |
| `ratelimit` | Per-user request rate limiting |
| `views` | HTML pages (server-rendered) |

## LynRummy

The project's main feature. See `games/lynrummy/ELM_TO_GO.md`
for port status. Three roles inside Gopher:

- **Dealer** (`lynrummy` package) — canned opening boards + canned
  two-player hands. Per-session seed makes replays reproducible.
- **Referee** (`lynrummy` package) — validates turn completion via
  protocol/geometry/semantics/inventory checks. Stateless.
- **Hint system** (`lynrummy/tricks` package) — seven trick
  recognizers walked in simplest-first priority order; each
  firing trick yields one representative suggestion. See
  `showell/claude_writings/hints_from_first_principles.md`.

The Elm client lives at `games/lynrummy/elm-port-docs/` and is
served via `/gopher/lynrummy-elm/`. A Python agent-side client
is at `tools/lynrummy_elm_player/`.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|---|---|
| `/gopher/` | Landing page |
| `/gopher/game-lobby` | Games launch pad (LynRummy + Critters) |
| `/gopher/lynrummy-elm/` | Elm LynRummy client |
| `/gopher/critters/` | Critter studies portal |
| `/gopher/dm` | Direct messages (Claude↔Steve) |
| `/gopher/wiki/` | Wiki viewer over repo source |
| `/gopher/docs/` | Essay viewer with inline comment widget |
| `/gopher/essays` | Essay index |
| `/gopher/claude/` | Claude landing page |
| `/gopher/claude-issues` | Issue tracker |
| `/gopher/users` | User directory |
| `/gopher/tour` | All CRUD pages |

## Ops

```
ops/start           Start prod servers (9000 + 8000)
ops/start_demo      Start demo servers with seeded data
ops/health_check    Verify server health
ops/import          Import external data
ops/list            List ops commands
```

## Testing

```bash
go test ./...          # all tests (~3s cold, ~1s warm)
go test ./games/...    # game logic only
go test -short ./...   # skip tagged long-runners
```

See `TESTING.md` for more.
