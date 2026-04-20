# Deployment

**As-of:** 2026-04-21
**Confidence:** Working — small ops surface, single-host WSL2 setup.
**Durability:** Stable until we deploy beyond Steve's WSL2 / single-host setup.

## Core principles

- **Safety over convenience.** No implicit defaults. Missing config →
  refuse to start with actionable error.
- **Data lives outside code.** DB + uploads under `~/AngryGopher/<mode>/`;
  `rm -rf` the source tree without affecting data (and vice versa).
- **Explicit modes.** `prod` (persistent) vs `demo` (recreated every start).
  Startup banner tells you which.

## Config

```json
{ "mode": "prod", "root": "/home/steve/AngryGopher/prod", "port": 9000 }
```

All fields required. Paths derived from `root`:
- `{root}/gopher.db` — SQLite database
- `{root}/uploads/` — reserved (uploads are currently unused)

## Starting

```bash
GOPHER_CONFIG=~/AngryGopher/prod.json ./gopher-server   # persistent
GOPHER_CONFIG=~/AngryGopher/demo.json ./gopher-server   # disposable
```

Demo mode destroys and recreates the DB on every start (seeds the
two canonical users, Steve=1 and Claude=2).

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
