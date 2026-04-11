# Testing Guide

## Running tests

```bash
go test -short ./...    # Fast suite (~7s) — skips stress tests
go test ./...           # Full suite (~21s) — includes stress tests
```

## Test speed analysis (April 2026)

**147 tests, 2.1s of actual test execution, ~7s wall clock.**

The bottleneck is not the tests — it's compile time. The
`modernc.org/sqlite` package (pure Go, transpiled from C) takes
~2.2s to compile the test binary. Each test averages 14ms. Running
a single test still takes 2.2s wall clock because compilation
dominates.

### Slow tests (tagged with -short skip)

| Test | Time | What it does |
|------|------|-------------|
| TestDB_ConcurrentSendMessage | 9.6s | 4 goroutines writing 100 messages each |
| TestStress_ConcurrentLoad | 4.5s | 4 users sending concurrently via HTTP |
| TestIntegration_RateLimiting | 2.1s | Exhausts rate limit window |

These are valuable stress tests but don't need to run on every
edit. Use `go test ./...` (without `-short`) for thorough checks.

## Sacred tests

Security tests are never skipped. These verify:
- Admin-only access for user management endpoints
- Non-admin rejection for all admin operations
- Deactivated users can't authenticate
- API key regeneration invalidates old keys
- DM privacy (third parties can't see your DMs)
- Buddy list privacy (no event leakage)
- Channel access control (private channels enforced)

## Bugs found during test cleanup

### Linkifier deadlock (April 2026)

**Symptom:** `TestCreatePublicChannel` hung for 60+ seconds.

**Root cause:** `processLinkifiers()` queried `github_repos`
during `renderMarkdown()`, which was called inside a transaction
in `HandleCreateChannel`. With `MaxOpenConns(1)` on in-memory
test databases, the query waited for the transaction's connection
— which would never release because it was waiting for
`renderMarkdown` to return. Classic single-connection deadlock.

**Fix:** Cache the repo list in memory (`linkifierRepos`),
refreshed on startup and when repos change. The markdown renderer
never touches the DB for linkification.

**Lesson:** Any function called during a transaction must not
make its own DB queries. When a function is used in multiple
contexts (HTTP handler vs. inside a transaction), the DB access
pattern must work for the most constrained context. Caching is
the natural solution when the data changes rarely.

## Test organization

All tests are in `package main` (not separate packages) and share
`resetDB()` for fresh in-memory databases. This avoids rogue
schemas — there is one source of truth in `schema/schema.go`.

The `resetDB()` function:
1. Creates a fresh `:memory:` SQLite database
2. Applies the full schema from `schema.Core`
3. Wires up all package DB references
4. Resets rate limiter, presence, and linkifier cache
5. Seeds test users, channels, and subscriptions

Tests that need specific data (repos, messages) insert it after
`resetDB()` using helpers like `sendMessage()`, `addRepo()`, etc.
