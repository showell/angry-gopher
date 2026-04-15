# Testing Guide

**As-of:** 2026-04-15
**Confidence:** Working — commands and numbers are Firm; "Lessons learned" section is Working as patterns evolve.
**Durability:** Stable for the current Go test layout; revisit when test infrastructure shifts.

## Running tests

```bash
go test -short ./...    # Fast suite — cached ~1s, cold ~7s
go test ./...           # Full suite — cached ~1s, cold ~21s
go test -count=1 ./...  # Force fresh (bypasses cache) — always slow
```

## Test speed analysis (April 2026)

**147 tests, 2.1s of actual test execution.**

### Go's build cache changes everything

| Scenario | Wall clock |
|----------|-----------|
| Cold cache, full suite | ~21s |
| Cold cache, `-short` | ~7s |
| **Warm cache, `-short`** | **~1.1s** |
| After touching one file | ~1.2s |
| Cold cache, single test | ~2.2s |

In normal development (warm cache), tests run in ~1 second.
The `-count=1` flag bypasses the cache and forces recompilation
— avoid it for routine iteration.

### Why cold starts are slow

The `modernc.org/sqlite` package (pure Go, transpiled from C)
is a 14-module dependency chain. Compiling it from scratch takes
~2.2s. This is a one-time cost per clean build — Go caches the
compiled package for subsequent runs.

Each test averages 14ms. The 147 tests contribute only 2.1s to
a cold run. The remaining ~5s is compilation and linking.

### Slow tests (tagged with -short skip)

| Test | Time | What it does |
|------|------|-------------|
| TestDB_ConcurrentSendMessage | 1.5s | 4 goroutines writing concurrently |
| TestStress_ConcurrentLoad | 1.2s | 4 users sending via HTTP concurrently |
| TestIntegration_RateLimiting | 0.3s | Exhausts rate limit window |

These are valuable stress tests but don't need to run on every
edit. Use `go test ./...` (without `-short`) for thorough checks.
Use `STRESS_MESSAGES=500` for thorough stress testing.

### Best practice for stress/integration tests

Write stress tests with high loop counts during initial
investigation — they help find race conditions and contention
bugs. Once the investigation is complete and the code is stable,
**reduce the loop counts** to keep the test suite fast. The test
still exercises the same code paths and concurrency patterns; it
just does fewer iterations. Keep the original counts documented
(or configurable via environment variables) so they can be
cranked back up for future investigations.

## Sacred tests

Security tests are never skipped. These verify:
- Admin-only access for user management endpoints
- Non-admin rejection for all admin operations
- DM privacy (third parties can't see your DMs)
- Channel access control (private channels enforced)

## Lessons learned

**Single-connection deadlock from in-transaction queries.** Any
function called during a transaction must not make its own DB
queries. When a function is used in multiple contexts (HTTP
handler vs. inside a transaction), the DB access pattern must
work for the most constrained context. Caching is the natural
solution when the data changes rarely. (Found via a markdown
renderer that queried a config table from inside
`HandleCreateChannel`'s transaction — hung for 60s under
`MaxOpenConns(1)`.)

## Test organization

All tests are in `package main` (not separate packages) and share
`resetDB()` for fresh in-memory databases. This avoids rogue
schemas — there is one source of truth in `schema/schema.go`.

The `resetDB()` function:
1. Creates a fresh `:memory:` SQLite database
2. Applies the full schema from `schema.Core`
3. Wires up all package DB references
4. Resets rate limiter and presence
5. Seeds test users, channels, and subscriptions

Tests that need specific data (repos, messages) insert it after
`resetDB()` using helpers like `sendMessage()`, `addRepo()`, etc.
