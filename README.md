# Angry Gopher

**As-of:** 2026-04-15
**Confidence:** Working — architecture is Firm; user/actor concept is actively being rewritten (see DECISIONS.md "Historical" + in-progress rip branch).
**Durability:** Architecture stable indefinitely; user/auth sections will churn until Player/Actor model lands.

A topic-based office chat server for small teams, backed by SQLite. Serves the Zulip API subset that [Angry Cat](https://github.com/showell/angry-cat) needs, plus Gopher-specific endpoints for games, DMs, search, and HTML views.

Angry Gopher treats LynRummy as a first-class citizen: it hosts games, deals cards, and runs a server-side referee that validates every move.

## Quick start

    bash ops/start

Starts the Gopher server on port 9000 and the Angry Cat dev server on port 8000. Uses the prod database at `~/AngryGopher/prod/gopher.db`.

For a fresh demo with seeded data:

    bash ops/start_demo

## Where to find what

If you're landing cold and need to find something fast:

| Looking for... | Read |
|---|---|
| **Design decisions + divergences from Zulip** | `DECISIONS.md` |
| **DB schema + query/index benchmarks** | `DATABASE.md` |
| **Long-polling event system internals** | `EVENTS.md` |
| **How to deploy / modes / backups** | `DEPLOYMENT.md` |
| **Day-to-day ops scripts** | `OPERATIONS.md` |
| **HTML page → endpoint mapping** | `VIEWS.md` |
| **Zulip API endpoint implementation status** | `API_ROADMAP.md` |
| **Test timings + organization + lessons** | `TESTING.md` |
| **Current task queue (follow-ups, in-flight work)** | `TASKS.md` |
| **Per-file domain knowledge + maturity** | `<file>.claude` sidecar next to any `.go` file |
| **Module-label index (INTRICATE, WORKHORSE, etc.)** | `LABELS.md` (generated) |
| **LynRummy ↔ Elm port status** | `lynrummy/ELM_TO_GO.md` |
| **How Steve & Claude collaborate** | `agent_collab/` |

Every `.go` file has a sibling `.claude` sidecar carrying its maturity + domain knowledge. When landing in unfamiliar code, read the sidecar first.

## Architecture

| Package | Role |
|---------|------|
| `auth` | HTTP Basic auth (base64 email:api_key) |
| `channels` | Channel CRUD, subscriptions, topics |
| `messages` | Send, edit, delete, render markdown |
| `events` | SSE-style long-polling event system |
| `search` | Full-text search via FTS5 trigram tokenizer |
| `flags` | Read/unread, starred message flags |
| `reactions` | Unicode emoji reactions |
| `dm` | Direct message conversations |
| `presence` | User presence tracking |
| `users` | User CRUD, settings |
| `games` | Game lobby host — matchmaking, event relay |
| `lynrummy` | LynRummy referee + dealer (card physics, no network) |
| `views` | HTML CRUD pages (server-rendered) |
| `schema` | Single source of truth for all DB tables |
| `respond` | JSON response helpers |
| `ratelimit` | Per-user request rate limiting |

## Gopher-specific endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /gopher/version | Server version and git commit |
| POST | /gopher/games | Create a game (accepts shuffled_deck for LynRummy) |
| GET | /gopher/games | List games for the current user |
| POST | /gopher/games/{id}/join | Join an existing game |
| POST | /gopher/games/{id}/events | Post a game event (referee-validated) |
| GET | /gopher/games/{id}/events | Poll for game events (long-poll supported) |

## LynRummy

Angry Gopher hosts LynRummy games with three roles:

- **Host** (`games` package) — authenticates players, relays events, manages game lifecycle. Knows which game type to route to which referee, but does not understand game rules.

- **Dealer** (`lynrummy` package) — sets up the game: pulls initial board stacks from the deck, deals hands, produces a GameSetup "photo" for the wire. Runs server-side for networked games.

- **Referee** (`lynrummy` package) — validates every move through four stages: protocol (JSON shape), geometry (board layout), semantics (valid card groups), inventory (card conservation). Stateless — you show it the board and the move, it gives a ruling.

Game creation is one round trip: the client sends a shuffled deck, the Host's Dealer deals and returns the GameSetup, and the game begins.

## HTML views

Server-rendered pages at `/gopher/*` with Basic auth:

| Page | Description |
|------|-------------|
| Messages | Browse messages with chunked progressive rendering |
| Recent | Recent conversations |
| Unread | Unread messages |
| Starred | Starred messages |
| Search | Full-text search |
| Channels | Channel list |
| DMs | Direct message conversations |
| Users | User directory |
| Games | Game lobby |

## Zulip-compatible API

Serves the `/api/v1/*` endpoints that Angry Cat needs for chat functionality: messages, channels, events, users, reactions, flags, uploads, presence, and subscriptions.

## Ops

Scripts in `ops/`:

| Script | Description |
|--------|-------------|
| `start` | Start prod servers (ports 9000 + 8000) |
| `start_demo` | Start demo servers with seeded data |
| `start_stress_server` | Start stress test server (port 9002) |
| `run_stress_test` | Run stress test against stress server |
| `health_check` | Check server health |
| `import` | Import data from Zulip |
| `list` | List ops commands |

## Testing

    go test ./...          # all tests
    go test ./lynrummy/    # referee + dealer tests only
    go test -short ./...   # skip slow tests

See `TESTING.md` for timings + lessons.
