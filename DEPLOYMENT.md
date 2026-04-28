# Deployment

**As-of:** 2026-04-21
**Confidence:** Working — small ops surface, single-host WSL2 setup.
**Durability:** Stable until we deploy beyond Steve's WSL2 / single-host setup.

## Core principles

- **Safety over convenience.** No implicit defaults. Missing config →
  refuse to start with actionable error.
- **Data lives outside code.** DB + uploads under `~/AngryGopher/prod/`;
  `rm -rf` the source tree without affecting data (and vice versa).
- **Single mode.** `prod` is the only mode now (demo retired
  2026-04-28; it was a Zulip-era artifact).

## Config

```json
{ "mode": "prod", "root": "/home/steve/AngryGopher/prod", "port": 9000 }
```

All fields required. Paths derived from `root`:
- `{root}/gopher.db` — SQLite database
- `{root}/uploads/` — reserved (uploads are currently unused)

## Starting

Use the canonical script:

```bash
bash ops/start
```

It kills any process on 9000/8000, rebuilds the Go binary,
recompiles the Elm clients, regenerates the puzzles catalog,
and waits for both ports before exiting. Don't invent ad-hoc
`go run` invocations.

## Backups

```bash
cp ~/AngryGopher/prod/gopher.db ~/AngryGopher/prod/backup_$(date +%Y%m%d).db
```

Do this before schema changes.

## Schema

Schema lives in `schema/schema.go` as the single source of truth.
No migrations: when the schema changes, back up the prod DB, apply
the diff by hand (ALTER TABLE) or re-seed, deploy new code.

## Tests vs deployment

Tests use `:memory:` SQLite. `go test` never touches a deployment
directory or config file.
