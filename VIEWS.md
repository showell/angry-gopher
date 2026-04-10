# HTML CRUD Views

Every API endpoint has a corresponding HTML page served by Angry
Gopher. These are thin layers over the API, authenticated via
Basic auth (browser caches credentials).

| View | API Endpoints | Features |
|------|--------------|----------|
| `/gopher/` | — | Master index page, links to all views |
| `/gopher/dm` | `dm/conversations`, `dm/messages` | List conversations, view messages, send |
| `/gopher/messages` | `messages` (GET/POST), `messages/{id}` | Browse channels > topics > messages, send |
| `/gopher/channels` | `subscriptions` (GET/POST), `streams/{id}` | List, create, edit description, view subscribers |
| `/gopher/users` | `users` (GET), `settings` (PATCH) | List users, edit own name, user detail pages |
| `/gopher/buddies` | `buddies` (GET/PUT) | Toggle buddies with checkboxes |
| `/gopher/github` | `github/repos` (GET/POST/DELETE) | Manage repo configs, show webhook URLs (admin-only) |
| `/gopher/game-lobby` | `games` (GET/POST), `games/{id}/*` | List/create games, view players and event log |

## Not covered (operational / no CRUD equivalent)

- Event queues (register, poll, delete) — operational
- Presence — transient, shown on ops dashboard
- Message flags (read/starred) — managed through message views
- Reactions — managed through message views
- Uploads — used inline in compose
- Server settings — on ops dashboard
- Invites — managed through Angry Cat plugin
- Games — managed through Angry Cat plugin
