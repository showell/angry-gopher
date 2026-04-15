# Operations Guide

## Quick start

```bash
# Demo mode (fresh seed data, disposable)
GOPHER_CONFIG=~/AngryGopher/demo.json ./gopher-server

# Production mode (persistent data)
GOPHER_CONFIG=~/AngryGopher/prod.json ./gopher-server
```

## Importing data from Zulip

The import tool fetches users, channels, and messages from a Zulip
server and writes them to a Gopher production database.

```bash
ops/import              # full import (default)
ops/import -mode tiny   # channels + 2 batches of messages
ops/import -mode empty  # schema only
```

If `~/AngryGopher/import_config.json` is missing, the script prints
setup instructions.

The import is idempotent — safe to rerun at any time. It skips
already-imported messages and picks up where it left off.

Config fields:
- `zulip_url` — the Zulip server (e.g. `https://macandcheese.zulipchat.com`)
- `zulip_email` — your Zulip email
- `zulip_api_key` — your Zulip API key (never commit this)
- `gopher_db` — path to the Gopher database
- `batch_size` — messages per API request (start with 10, use 5000 for full import)

## Backups

```bash
cp ~/AngryGopher/prod/gopher.db ~/AngryGopher/prod/backup_$(date +%Y%m%d).db
```

Do this before schema migrations or risky changes.

## User credentials

After import, each user gets a random 32-character API key. Look them
up in the admin UI at http://localhost:9000/admin/users or via:

```bash
sqlite3 ~/AngryGopher/prod/gopher.db "SELECT full_name, email, api_key FROM users"
```

## Directory layout

```
~/AngryGopher/
    prod.json               Config for production
    demo.json               Config for demo
    import_config.json      Zulip import credentials (not in git)
    prod/
        gopher.db           Production database
        uploads/            Uploaded files
    demo/
        gopher.db           Demo database (recreated on start)
        uploads/            Demo uploads

~/showell_repos/angry-gopher/
    (source code only — no data)
```
