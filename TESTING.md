# Testing Guide

**As-of:** 2026-04-18
**Confidence:** Working — numbers reflect today's suite after
the Zulip-compliance and legacy-game-lobby rips.

## Running tests

```bash
go test ./...           # Full suite — ~3s cold, ~1s warm
go test -short ./...    # Skip tagged long-runners — ~1.6s cold
go test -count=1 ./...  # Bypass cache — always cold
```

## Size and shape

**104 tests across 4 packages** (`angry-gopher`,
`games/lynrummy`, `games/lynrummy/tricks`, `ratelimit`).

Every individual test is sub-10ms. No current test needs
`-short` to hide it; the flag is preserved for future
stress/integration tests that may grow loop counts during
investigation.

## Go's build cache dominates wall time

The `modernc.org/sqlite` package (pure-Go, transpiled C) is the
long pole on cold builds. Once Go's build cache is warm, the
actual test execution is ~1s; cold builds add a few seconds for
the compile step. Avoid `-count=1` for routine iteration — use
it only when you need to bypass cached test results.

## Stress/integration pattern

When investigating a race or contention bug, write the test
with high loop counts. Once the investigation lands, **reduce
the loop counts** to keep the routine suite fast. Parameterize
via env var (e.g. `STRESS_MESSAGES=500`) if you want the
cranked-up version still available.

## Test organization

All tests in `package main` (at the repo root) share `resetDB()`
for fresh in-memory databases. Single source of schema truth is
`schema/schema.go` — tests never hand-write schema.

`resetDB()`:

1. Fresh `:memory:` SQLite
2. Applies `schema.Core`
3. Wires all package DB references
4. Resets rate limiter + presence
5. Seeds minimal test users

Tests that need extra state insert it after `resetDB()` via
helpers (`sendMessage()`, `addRepo()`, etc.).

## One durable lesson

**Single-connection deadlock from in-transaction queries.** A
function called during a transaction must not issue its own DB
queries. When a helper is used in multiple contexts (HTTP
handler + inside a transaction), the DB access pattern must
work for the most constrained context. Caching is the natural
escape when the queried data changes rarely. Found via a
markdown renderer that queried a config table from inside
`HandleCreateChannel`'s transaction — hung for 60s under
`MaxOpenConns(1)`.

Others will accumulate here as we hit them.
