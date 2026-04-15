# Design Decisions

**As-of:** 2026-04-15
**Confidence:** varies per entry (tagged inline).
**Durability:** reviewed during weekly audits; last audit 2026-04-15.

Angry Gopher is not a Zulip clone. It is a topic-based office chat system for a targeted niche of users. This document records intentional divergences from Zulip and key design choices.

Each entry is tagged with a confidence tier:
- **Firm** — we believe this, have acted on it, unlikely to revisit soon.
- **Working** — current best; acting on it; would revise under pressure.
- **Tentative** — not yet stress-tested; may not survive.

## Extra features (Gopher has, Zulip doesn't)

**Game engine.** [Firm] LynRummy is playable within Angry Cat. The server hosts game state via `/gopher/` endpoints.

## Deliberately missing features

**No stream colors.** [Firm] Zulip lets each user pick a color per channel. We don't track or render stream colors. Channels are visually distinguished by name only.

**No scheduled messages.** [Firm] Zulip supports scheduling messages for future delivery. We don't see this as necessary for our use case and won't add first-class server support for it.

**No user groups.** [Firm] Zulip has org-wide user groups that admins manage. They tend to be a misfeature — individual users can't customize them, and at our target scale they add complexity without value.

**No channel folders.** [Firm] Zulip lets admins organize channels into folders. Same problem as user groups — org-wide, not per-user customizable. At our scale, a flat channel list is fine.

## Architecture

**One server per org, medium scale.** [Firm] Zulip is designed for large multi-tenant deployments with PostgreSQL, Redis, RabbitMQ, and memcached. We run one Gopher process per organization backed by a single SQLite file. This gives us Go's concurrency with SQLite's simplicity — one binary, one database file, trivial backups and migrations. We're targeting teams, not platforms.

**No schema migrations.** [Firm] `schema/schema.go` is the single source of truth for all tables. When schema changes, the DB rebuilds + data re-imports. ALTER TABLE statements anywhere in the repo are a smell.

## Under consideration

**No group DMs.** [Working] Group DMs add significant complexity to the data model and event system. We'd rather solve the underlying need — quick private conversations among a few people — by making it easy to create small private channels. Postponed indefinitely.

## Shared features with different approaches

**Pessimistic updates.** [Firm] When the server is involved, the UI waits for confirmation before updating local state. The compose box disables while sending. Zulip uses optimistic updates in many places. We chose pessimistic uniformly for simplicity and correctness.

**UI engine: Elm by default.** [Working, 2026-04-13] New UI work scaffolds in Elm. LynRummy is being ported from its TypeScript home in Angry Cat to Elm incrementally; the TS version stays alive during the port and retires once the Elm version covers the same surface. Trigger was the elm-cows port (~/showell_repos/elm-cows), which delivered a bug-free first-play through a 2-round game with substantially fewer agent debug cycles than the JS equivalent. Gopher pages with high UI demands may support both Elm and plain HTML/JS as appropriate — read-mostly pages stay in plain HTML. Not a one-way door: if a real LynRummy feature pushes back on Elm, we reassess.

## Security patterns

**Webhook signature verification.** [Firm, principle] Motivation: a public webhook URL is reachable by anyone on the internet, so we need to confirm the request actually came from the third party and not a spammer. Three constraints are load-bearing: (a) HMAC over the raw body, not the parsed form — any re-serialization breaks it; (b) constant-time compare to prevent timing attacks; (c) verify *before* parsing, so a malformed payload can't crash you before rejection.

## Historical

**GitHub integration** (removed 2026-04-15). A first-class GitHub integration existed (webhook receiver, repo config, linkifiers, admin UI). Ripped when we pivoted to get the user/actor concept right before adding peripheral features back. Two design insights survive:

- **Linkifiers = repo config.** When auto-linking repo references (`#123`, `AG#123`), the set of tracked repos is already the source of truth — avoid a second config registry. Prefix disambiguation scales from 1 to N repos without new UI surface.
- **Single-case cheap, disambiguation only on demand.** When one namespace is common and N is rare, the one-case syntax should carry zero prefix cost (`#123`); prefixes (`AG#123`, `AC#456`) appear only when ambiguity is real.

**User-concept rip-to-bones** (in progress 2026-04-15). Ripped `user_sessions`, `regenerate_api_key`, `buddies`, `muted_users`, `muted_topics`, `invites`, `is_active` + deactivate/reactivate, along with ~1500 LOC of Zulip-checkbox scaffolding around users. Motivation: before adding the Actor/Player model (provenance principle), strip everything that wasn't earning its keep. We can re-add piece by piece when pressure returns. Each feature's removal preserved earned-experience knowledge inline or in `feedback_*.md` memory.
