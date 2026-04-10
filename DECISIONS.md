# Design Decisions

Angry Gopher is not a Zulip clone. It is a topic-based office chat
system for a targeted niche of users. This document records intentional
divergences from Zulip and key design choices.

## Extra features (Gopher has, Zulip doesn't)

**Server-side buddy lists.** Users can curate a list of people they
care about seeing in the sidebar. Zulip has no buddy concept — only
presence. Persisted via `GET/PUT /api/v1/buddies`.

**Server session tracking.** Each server start gets a generation
number. User logins are recorded with their generation. The ops
dashboard and health check expose this. Zulip has no equivalent.

**Game engine.** LynRummy is playable within Angry Cat. The server
hosts game state via `/gopher/` endpoints.

## Deliberately missing features

**No stream colors.** Zulip lets each user pick a color per channel.
We don't track or render stream colors. Channels are visually
distinguished by name only.

**No scheduled messages.** Zulip supports scheduling messages for
future delivery. We don't see this as necessary for our use case
and won't add first-class server support for it.

**No user groups.** Zulip has org-wide user groups that admins
manage. They tend to be a misfeature — individual users can't
customize them, and at our target scale they add complexity
without value.

**No channel folders.** Zulip lets admins organize channels into
folders. Same problem as user groups — org-wide, not per-user
customizable. At our scale, a flat channel list is fine.

## Architecture

**One server per org, medium scale.** Zulip is designed for large
multi-tenant deployments with PostgreSQL, Redis, RabbitMQ, and
memcached. We run one Gopher process per organization backed by a
single SQLite file. This gives us Go's concurrency with SQLite's
simplicity — one binary, one database file, trivial backups and
migrations. We're targeting teams, not platforms.

## Shared features with different approaches

**Server settings returns generation, not Zulip's full payload.**
`GET /api/v1/server_settings` returns only the server generation
number. Zulip returns a large blob of feature flags, auth backends,
and realm info. We'll add fields as needed but won't mirror the
Zulip shape.

**Pessimistic updates.** When the server is involved, the UI waits
for confirmation before updating local state. The compose box
disables while sending; the buddy checkbox disables during toggle.
Zulip uses optimistic updates in many places. We chose pessimistic
uniformly for simplicity and correctness.
