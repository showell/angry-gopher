# Database Decisions

Design choices for Angry Gopher's SQLite database. All benchmarks
are against a 10M message test database with realistic distribution
(50 users, 30 channels, 538 topics, power-law activity).

## Core principles

**Schema is the single source of truth.** The schema lives in
`schema/schema.go`. Both the server and the import tool use it.
There are no migrations — data is disposable and can be re-imported
from Zulip at any time.

**Content rows are immutable.** Content tables (`message_content`,
`channel_descriptions`) are never updated. When a message is edited,
we INSERT a new content row and UPDATE the message's `content_id`
pointer. The old row stays forever — free edit history, no audit
table. The FK update is a cheap integer write; the expensive text
data is never mutated. This makes content rows cache-friendly and
safe for concurrent reads.

**No consistency guarantees on content reads.** We never wrap
search + hydration in a transaction or retry on races. If a message
is edited between the ID query and the content fetch, the user sees
whichever version the query hits — old or new. Both are valid,
because every version is a complete content row (no torn reads).
Users take seconds to read messages; worrying about sub-millisecond
race windows is pointless.

**IDs are not secrets.** Auto-increment IDs for messages, content,
topics, and users are exposed directly to clients. The approximate
size of any Angry Gopher database can be inferred from the IDs.
We make no effort to obscure this — no UUIDs, no hash IDs, no
random offsets. Sequential integers are simple, fast for indexes,
and compact on the wire. Organizations that need to hide their
message volume should look elsewhere.

**Clients get both markdown and HTML.** The hydration endpoint
returns both `markdown` and `html` for each message. Clients
don't need to choose — they get the raw source and the rendered
output in one response. This avoids a re-render on the client
side and lets the client use whichever format fits the context
(HTML for display, markdown for editing).

**Search returns IDs, not content.** Search API endpoints return
lightweight rows: message_id, content_id, channel_id, topic_id,
and sender_id. No HTML, no markdown, no user names. The client
hydrates what it needs in a second request. This keeps search
responses fast and small. Combined with immutable content rows,
the content_id serves as a natural cache key — if the message's
content_id hasn't changed, the cached content is still valid.

## Content separation

Rendered text (markdown + HTML) is stored in dedicated tables rather
than inline on the parent row. This keeps the core tables lean and
allows ops access to structural data without exposing user content.

## Indexes

### The critical pagination index

```sql
CREATE INDEX idx_messages_channel_id_desc ON messages(channel_id, id DESC);
```

This is the most important index in the system. Without it, SQLite
chooses a channel-only index for filtering, then loses the ability
to walk the primary key in reverse for `ORDER BY id DESC LIMIT N`.

| Query | Without | With |
|-------|---------|------|
| Recent 50 in channel | 474ms | 39µs |

The compound `(channel_id, id DESC)` index lets SQLite satisfy
both the WHERE and ORDER BY from a single index walk, stopping
at the LIMIT without scanning.

### Supporting indexes

```sql
CREATE INDEX idx_messages_channel_topic ON messages(channel_id, topic_id);
CREATE INDEX idx_messages_sender ON messages(sender_id);
```

| Query | No index | Indexed | Speedup |
|-------|----------|---------|---------|
| Channel filter | 1.66s | 175ms | 10x |
| Channel + topic | 2.59s | 522ms | 5x |
| Sender filter | 1.68s | 89ms | 19x |

### What we learned about the query planner

SQLite's planner is **not tricked by WHERE clause order.** We
tested all 6 permutations of channel + topic + sender in the
WHERE clause — SQLite picks the same plan every time.

For a query filtering on channel, topic, and sender simultaneously,
SQLite chooses the sender index (most selective single column)
rather than the channel+topic composite. This looks suboptimal —
sender_id=1 matches 200K rows while channel+topic matches ~460 —
but with `LIMIT 50` it doesn't matter. SQLite scans the sender
index, filters by channel+topic in memory, and stops at 50 results
in ~400µs.

A triple composite index `(channel_id, topic_id, sender_id)` was
tested and made no difference — SQLite still preferred the sender
index. We dropped it.

**Takeaway:** sequential scans are fast. Modern hardware reads
cache lines linearly at enormous throughput. An index that narrows
to 200K rows followed by an in-memory filter is ~400µs — faster
than the overhead of a more "optimal" index-hop strategy. Trust
the planner, benchmark before adding indexes, and remember that
LIMIT changes everything.

## Buddy filtering (OR/IN queries)

A common query: "show me messages in this topic, but only from
my buddies." Tested OR chains, IN clauses, temp tables, and
subquery IN across buddy list sizes of 2-20 at 10M rows.

**With LIMIT 50 (the real-world case):** ~400µs regardless of
buddy count. 2 buddies or 20 — doesn't matter. The IN clause
is the right choice: simple code, fast execution.

| Approach | 2 buddies | 20 buddies |
|----------|-----------|-----------|
| OR chain | 107ms | 146ms |
| IN clause | 91ms | 125ms |
| Temp table | 100ms | 98ms |
| IN + LIMIT 50 | **2.6ms** | **0.4ms** |

**Surprising finding:** filtering by sender on top of channel+topic
is *slower* than no filter at all (90-145ms vs 3.6ms). The
channel+topic index already narrows to ~23K rows; adding a sender
check on each row costs more than it saves because it can't use
an index within that set. The sender filter only pays for itself
when combined with LIMIT, which lets SQLite stop early.

**Takeaway:** use IN clause for buddy filtering. Don't bother
with temp tables or OR chains — they're slower or more complex
for no benefit. LIMIT makes everything fast.

## Two-trip hydration pattern

For search and pagination, fetch message IDs first, then hydrate
content in a second query using `WHERE m.id IN (...)`.

Why this is faster than a single join:

1. The ID query touches only indexes — no content data loaded
2. The hydration does targeted PK lookups on `message_content`
3. Content data never flows through the sort

| Approach | 50 rows | 23K rows |
|----------|---------|----------|
| IDs only | 4.9ms | 3.0s |
| Single join | — | 6.3s |
| Two-trip (IDs + IN) | **5.6ms** | **3.7s** |

The pattern also pairs naturally with caching — if some content
rows are already cached, only hydrate the missing ones.

### IN clause limits

SQLite caps at 32,766 bind variables per query.

| IDs | IN clause | Temp table |
|-----|-----------|-----------|
| 1,000 | 6ms | — |
| 10,000 | 213ms | 133ms |
| 50,000 | ERROR | 679ms |
| 100,000 | ERROR | 984ms |

**Strategy:** use IN for up to 10K IDs (covers virtually all
real search results). For rare bulk operations, batch in chunks
of 10K. Temp tables work beyond the limit but the insert cost
dominates at large sizes — not worth the complexity.

## Benchmark tools

Generate a test database:
```bash
go run ./cmd/gen_test_data -db /tmp/gopher_bench.db -messages 10000000
```

Run search benchmarks:
```bash
go run ./cmd/bench_search -db /tmp/gopher_bench.db
```

Run hydration benchmarks:
```bash
go run ./cmd/bench_hydrate                # two-trip comparison
go run ./cmd/bench_hydrate -limit-test    # IN clause scaling
```

Test query planner behavior:
```bash
go run ./cmd/bench_planner
```

Test buddy/OR query behavior:
```bash
go run ./cmd/bench_or
```

The 10M test database takes ~8 minutes to generate — keep it
around for iterating.
