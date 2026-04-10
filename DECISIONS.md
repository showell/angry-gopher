# Design Decisions

Angry Gopher is not a Zulip clone. It is a topic-based office chat
system for a targeted niche of users. This document records intentional
divergences from Zulip and key design choices.

## API

**Server settings returns generation, not Zulip's full payload.**
`GET /api/v1/server_settings` returns only the server generation
number. Zulip returns a large blob of feature flags, auth backends,
and realm info. We'll add fields as needed but won't mirror the
Zulip shape.

## UI principles

**Pessimistic updates.** When the server is involved, the UI waits
for confirmation before updating local state. The compose box
disables while sending; the buddy checkbox disables during toggle.
This applies uniformly — even localStorage saves follow the same
code path shape for consistency.
