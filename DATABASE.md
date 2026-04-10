# Database Decisions

Design choices for Angry Gopher's SQLite database.

## Schema is the single source of truth

The schema lives in `schema/schema.go`. Both the server and the
import tool use it. There are no migrations — data is disposable
and can be re-imported from Zulip at any time.

## Content separation

Rendered text (markdown + HTML) is stored in dedicated tables
(`message_content`, `channel_descriptions`) rather than inline on
the parent row. This keeps the core tables lean and allows ops
access to structural data without exposing user content.

## Content rows are immutable

Content tables (`message_content`, `channel_descriptions`) are
never updated. When a message is edited:

1. INSERT a new row into `message_content` with the new text
2. UPDATE `messages.content_id` to point to the new row

The old content row stays forever — it's the edit history for
free, with no separate audit table. The FK update on `messages`
is a cheap integer write. The content row itself, which holds
the expensive text data, is never mutated.

This makes content rows cache-friendly and safe for concurrent
reads. It also means `message_content` can be treated as an
append-only log if we ever need replication or backup strategies.

## The critical pagination index

```sql
CREATE INDEX idx_messages_channel_id_desc ON messages(channel_id, id DESC);
```

This is the most important index in the system. Without it, SQLite
chooses a channel_id-only index for filtering, but then loses the
ability to walk the primary key in reverse for `ORDER BY id DESC
LIMIT N` queries. The result at 10M rows:

| Query | Without | With |
|-------|---------|------|
| Recent 50 in channel | 474ms | 39µs |

The compound `(channel_id, id DESC)` index lets SQLite satisfy
both the WHERE and ORDER BY from the same index, stopping at the
LIMIT without scanning.

## Other indexes

```sql
CREATE INDEX idx_messages_channel_topic ON messages(channel_id, topic_id);
CREATE INDEX idx_messages_sender ON messages(sender_id);
```

At 10M rows:
- **Channel filter**: 175ms (8x faster than no index)
- **Sender filter**: 93ms (19x faster)
- **Channel + topic**: 522ms (5x faster)

## Benchmark data

A 10M message test database can be generated with:
```bash
go run ./cmd/gen_test_data -db /tmp/gopher_bench.db -messages 10000000
```

Benchmarks can be run with:
```bash
go run ./cmd/bench_search -db /tmp/gopher_bench.db
```

The test database at `/tmp/gopher_bench.db` is expensive to
generate (~8 minutes) — keep it around for iterating on indexes.
