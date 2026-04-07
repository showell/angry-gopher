# Event System

This document explains how Angry Gopher delivers real-time updates to
clients. If you've worked with WebSockets, this will feel familiar —
but we use HTTP long-polling instead, which is simpler and works
everywhere without special infrastructure.

## How it works

### Registration

When Angry Cat starts up, it sends `POST /api/v1/register` to create
an **event queue**. The server returns a `queue_id` that the client
uses for all subsequent polling. Each queue is tied to the
authenticated user's ID, which matters for permission filtering later.

A user can have multiple queues (e.g. if they open two browser tabs).
Each queue is independent.

### Long-polling

The client enters a loop: it sends `GET /api/v1/events?queue_id=X&last_event_id=N`
and the server either:

1. **Returns immediately** if there are events with IDs greater than N.
2. **Blocks for up to 50 seconds** waiting for new events.
3. **Returns a heartbeat** if the 50 seconds expire with no events.

The client processes the events, updates its `last_event_id` to the
highest ID it received, and immediately polls again. This creates a
near-real-time stream with no special protocols — just HTTP.

### Event delivery

When something happens (a message is sent, a flag is updated, a
reaction is added), the handler calls one of two functions:

- **`PushToAll(event)`** — delivers the event to every registered queue.
  Used for events that are relevant to all users, like flag updates
  (which only contain message IDs, not content).

- **`PushFiltered(event, filter)`** — delivers the event only to queues
  whose owner passes the filter function. Used for events that depend
  on channel access permissions. For example, when a message is sent
  to a private channel, only users who are subscribed to that channel
  receive the event.

Both functions run synchronously: they iterate all queues, copy the
event (so each queue gets its own event ID), append it, and wake up
any long-polling goroutine that's waiting.

### There is no background queue

Events are delivered **immediately and synchronously** during the HTTP
handler that created them. When `HandleSendMessage` calls `PushFiltered`,
the event is appended to all eligible queues before the handler returns
its HTTP response. There is no background worker, no message broker,
no eventual consistency — just a mutex-protected append to an in-memory
slice.

This is simple and correct for our scale. The tradeoff is that event
delivery adds latency to the originating request (one mutex acquisition
per queue). At thousands of concurrent queues, this could become a
bottleneck, but for our use case it's well under a millisecond.

### Per-queue event IDs

Each queue assigns its own sequential event IDs. When the same event
is pushed to 4 queues, each copy gets a different ID (e.g. queue A
gets ID 7, queue B gets ID 12). This is because each client tracks
its own `last_event_id` independently.

### Memory management

Event queues grow without bound for now. In production, we would
want to:
- Expire queues that haven't been polled recently
- Trim old events that all clients have already consumed
- Set a maximum queue depth

For development, the DB resets on every server restart, and queues
are in-memory, so this isn't a concern yet.

## Rate limiting

Angry Gopher enforces per-user rate limiting to prevent abuse. The
current settings are 120 requests per 60-second sliding window.

### How it works

The `withCORS` middleware checks every authenticated request against
the rate limiter before passing it to the handler. If the user has
exceeded their limit, the server returns:

```
HTTP 429 Too Many Requests
Retry-After: 60
{"result": "error", "msg": "Rate limit exceeded"}
```

Angry Cat's `with_retry` helper automatically retries on 429, waiting
for the `Retry-After` duration before trying again.

### Why event polling is exempt

The `GET /api/v1/events` endpoint is **not rate-limited**, even though
it requires authentication. There are two reasons:

1. **It's passive.** The client is listening for updates, not causing
   server-side state changes. Rate limiting exists to prevent users
   from overwhelming the server with writes — reads from a long-poll
   are cheap (the goroutine just sits in a `select` waiting).

2. **It would break the protocol.** A long-poll returns after up to
   50 seconds, and the client immediately re-polls. That's roughly
   1 request per minute — but during a burst of activity, the client
   may poll several times in quick succession as it processes batches
   of events. Rate-limiting these would cause the client to fall
   behind on events, see stale data, and eventually re-register its
   queue (losing event history).

### What counts against the limit

Every other authenticated API request counts: sending messages,
updating flags, adding reactions, editing messages, uploading files,
registering queues, etc. The limit is generous enough for normal
usage (Angry Cat's page load requires about 5 requests) but will
catch automated abuse.

## Event types

| Event type | Trigger | Delivery |
|------------|---------|----------|
| `message` | New message sent | Filtered by channel access |
| `update_message` | Message edited | Filtered by channel access |
| `update_message_flags` | Flags changed (read/starred) | All queues |
| `reaction` | Reaction added/removed | Filtered by channel access |
| `stream` | Channel description updated | Filtered by channel access |
| `subscription` | Channel created | Filtered to subscribed users |
| `heartbeat` | 50-second poll timeout | Single queue (the one that timed out) |
