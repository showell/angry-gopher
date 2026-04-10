# Design Decisions

Angry Gopher is not a Zulip clone. It is a topic-based office chat
system for a targeted niche of users. This document records intentional
divergences from Zulip and key design choices.

## API

**Buddy list uses PUT, not PATCH.** The buddy list is a private,
user-scoped blob — the client always sends the full list. This is
the first Gopher-only endpoint (`/api/v1/buddies`) and intentionally
differs from the PATCH-based partial updates used on Zulip-compat
endpoints.

**Buddy changes do not generate events.** Buddy lists are private.
No events are pushed to any queue when a user updates their buddies.
This is enforced by tests.

**Server settings returns generation, not Zulip's full payload.**
`GET /api/v1/server_settings` returns only the server generation
number. Zulip returns a large blob of feature flags, auth backends,
and realm info. We'll add fields as needed but won't mirror the
Zulip shape.

## Data model

**Server sessions are tracked in the database.** Each server start
gets a generation number (auto-increment). User logins (queue
registrations) are recorded with the generation they connected to.
Zulip has no equivalent — this is ops tooling unique to Gopher.

**Buddy lists are server-side on Gopher, client-side on Zulip.**
On Zulip realms, Angry Cat stores buddy preferences in localStorage
(Zulip has no buddy API). On Gopher realms, they're persisted via
the server API. The client detects the backend and chooses
accordingly.

## UI principles

**Pessimistic updates.** When the server is involved, the UI waits
for confirmation before updating local state. The compose box
disables while sending; the buddy checkbox disables during toggle.
This applies uniformly — even localStorage saves follow the same
code path shape for consistency.
