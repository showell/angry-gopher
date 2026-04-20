# Testing

**As-of:** 2026-04-21
**Confidence:** Working.

## Running

```bash
go test ./...           # full suite
go test -short ./...    # skip tagged long-runners
go test -count=1 ./...  # bypass cache
```

Every test is sub-10ms. Cold builds are dominated by the
`modernc.org/sqlite` compile (pure-Go transpiled C); warm
iteration is ~1s.

## Organization

All tests in `package main` share `resetDB()` for fresh
in-memory databases. Schema comes from `schema/schema.go` —
tests never hand-write schema.

`resetDB()` applies the schema to a fresh `:memory:` DB, wires
all package DB references, and seeds minimal users.

## Stress/integration

When chasing a race, crank loop counts temporarily; reduce
before merging. Parameterize via env var (e.g.
`STRESS_MESSAGES=500`) if the cranked version is worth keeping
around.

## One durable lesson

**Single-connection deadlock from in-transaction queries.** A
helper called during a DB transaction must not issue its own
DB queries. Under `MaxOpenConns(1)` this hangs the process.
When a helper is shared across handler + transaction contexts,
its access pattern must match the most constrained context;
caching is the usual escape.
