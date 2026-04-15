# Design Decisions

Angry Gopher is not a Zulip clone. It is a topic-based office chat
system for a targeted niche of users. This document records intentional
divergences from Zulip and key design choices.

## Extra features (Gopher has, Zulip doesn't)

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

## Under consideration

**1:1 DMs.** Zulip supports both 1:1 and group DMs. We have no
DM support yet on the server side (Angry Cat has client-side DM
support against Zulip). We'll likely add 1:1 DMs eventually but
haven't committed to the approach.

**No group DMs.** Group DMs add significant complexity to the data
model and event system. We'd rather solve the underlying need —
quick private conversations among a few people — by making it easy
to create small private channels. Postponed indefinitely.

## Shared features with different approaches

**Pessimistic updates.** When the server is involved, the UI waits
for confirmation before updating local state. The compose box
disables while sending. Zulip uses optimistic updates in many
places. We chose pessimistic uniformly for simplicity and correctness.


**UI engine: Elm by default (2026-04-13).** New UI work scaffolds
in Elm. LynRummy is being ported from its TypeScript home in Angry
Cat to Elm incrementally; the TS version stays alive during the
port and retires once the Elm version covers the same surface.
Trigger was the elm-cows port (~/showell_repos/elm-cows), which
delivered a bug-free first-play through a 2-round game with
substantially fewer agent debug cycles than the JS equivalent.
Gopher pages with high UI demands may support both Elm and plain
HTML/JS as appropriate — read-mostly pages stay in plain HTML.
Not a one-way door: if a real LynRummy feature pushes back on
Elm, we reassess.

## Security patterns

**Webhook signature verification.** Motivation: a public webhook
URL is reachable by anyone on the internet, so we need to confirm
the request actually came from the third party and not a spammer.
Three constraints are load-bearing: (a) HMAC over the raw body,
not the parsed form — any re-serialization breaks it; (b)
constant-time compare to prevent timing attacks; (c) verify
*before* parsing, so a malformed payload can't crash you before
rejection.

## Historical

**GitHub integration (removed 2026-04-15).** A first-class GitHub
integration existed (webhook receiver, repo config, linkifiers,
admin UI). Ripped when we pivoted to get the user/actor concept
right before adding peripheral features back. Two design insights
survive:

- **Linkifiers = repo config.** When auto-linking repo references
  (`#123`, `AG#123`), the set of tracked repos is already the
  source of truth — avoid a second config registry. Prefix
  disambiguation scales from 1 to N repos without new UI surface.
- **Single-case cheap, disambiguation only on demand.** When one
  namespace is common and N is rare, the one-case syntax should
  carry zero prefix cost (`#123`); prefixes (`AG#123`, `AC#456`)
  appear only when ambiguity is real.
