# Deployment Philosophy

## Core principles

**Safety over convenience.** The server requires explicit configuration
for everything and will not assume defaults. If information is missing,
it refuses to start and tells you exactly what to do. We would rather
make the operator type one extra line than silently do the wrong thing.

**Data lives outside code.** The database, uploaded files, and config
files all live in a deployment directory (e.g. `~/AngryGopher/prod/`),
completely separate from the source code. The code directory contains
only source, build artifacts, and test files. You can `rm -rf` the
code directory without affecting any data, and vice versa.

**Explicit modes.** Every deployment is either `prod` (persistent,
never reset) or `demo` (disposable, recreated on every start).
There is no ambiguity about which mode you're in — the startup
banner tells you.

## Configuration

Each deployment has a JSON config file:

```json
{
    "mode": "prod",
    "root": "/home/steve/AngryGopher/prod",
    "port": 9000
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `mode` | Yes | `"prod"` or `"demo"` |
| `root` | Yes | Root directory for all deployment data |
| `port` | Yes | Port to listen on |

The server derives all paths from `root`:
- `{root}/gopher.db` — SQLite database
- `{root}/uploads/` — uploaded files

Directories are auto-created on startup if they don't exist.

## Starting the server

```bash
# Production — opens existing database, never seeds or resets
GOPHER_CONFIG=~/AngryGopher/prod.json ./gopher-server

# Demo — destroys and recreates database with seed data
GOPHER_CONFIG=~/AngryGopher/demo.json ./gopher-server
```

Without `GOPHER_CONFIG`, the server refuses to start and prints
a help message.

## Demo mode

Demo mode (`"mode": "demo"`) is for development and testing:
- Destroys the database on every start
- Seeds 4 users, 3 channels, 25 test messages
- Creates a test image in the uploads directory
- Safe to restart at any time — all data is disposable

## Production mode

Production mode (`"mode": "prod"`) is for real usage:
- Opens the existing database (creates schema if first run)
- Never seeds or resets — your data accumulates over time
- Users are created via the invite system
- Channels are created via the Angry Cat admin plugin

## Backups

The database is a single SQLite file. Back it up by copying:

```bash
cp ~/AngryGopher/prod/gopher.db ~/AngryGopher/prod/backup_$(date +%Y%m%d).db
```

Do this before schema migrations, risky changes, or periodically.

## Schema migrations

For now, schema migrations are done manually. When we change the
schema in code:

1. Back up the production database
2. Write the migration SQL (ALTER TABLE, etc.)
3. Run it against the database: `sqlite3 prod/gopher.db < migration.sql`
4. Deploy the new code

We'll build a formal migration system when we have more than one
production instance.

## Automated tests

Tests are completely separate from deployment. They use in-memory
SQLite (`:memory:`), never touch the filesystem, and don't need
a config file. Running `go test` has no effect on any deployment.

## Directory layout

```
~/AngryGopher/
    prod.json           Config for production
    demo.json           Config for demo
    prod/
        gopher.db       Production database (persistent)
        uploads/        Production uploaded files
    demo/
        gopher.db       Demo database (recreated on start)
        uploads/        Demo uploaded files

~/showell_repos/angry-gopher/
    (source code only — no data)
```
