# Stress Testing

Run realistic bot clients against a live Angry Gopher server while
watching the ops dashboard.

## Setup

Start the stress server (port 9002, demo mode, own database):

```bash
cd ~/showell_repos/angry-gopher
go build -o angry-gopher .
GOPHER_CONFIG=~/AngryGopher/stress.json ./angry-gopher 2>&1 | tee /tmp/gopher-stress.log
```

The config is at `~/AngryGopher/stress.json`:

```json
{
    "mode": "demo",
    "root": "/home/steve/AngryGopher/stress",
    "port": 9002
}
```

## Ops dashboard

Once the server is running, open the dashboard in your browser:

```
http://localhost:9002/admin/ops
```

The dashboard auto-refreshes every 10 seconds and shows:
- **Event Queues** -- queue count, pending events, last event ID per queue
- **Presence** -- which users are online/offline, last seen times
- **Rate Limiting** -- requests per user in the current window, headroom, total 429s served
- **Server Info** -- mode, database path, listen address

## Seed data

Before running bots, you can seed the database with messages.
The `-seed` flag sends messages through the API, so they go through
the full handler path including DB writes, event emission, and
markdown rendering.

```bash
go run ./cmd/stress -seed 500
```

This sends 500 messages spread across 4 users, 2 channels, and
10 topics. Scale up or down as needed.

## Run bots

Bots run until you press Ctrl-C:

```bash
go run ./cmd/stress               # 4 bots
go run ./cmd/stress -bots 2       # fewer bots
go run ./cmd/stress -seed 200     # seed 200 messages, then run bots
```

Each bot:
- Registers an event queue and long-polls for events
- Sends a presence heartbeat every 60 seconds
- Sends a message every 10-30 seconds
- Occasionally edits its last message or adds a reaction

On Ctrl-C, prints a summary of messages sent and events received.

## Tail the logs

In a separate terminal:

```bash
tail -f /tmp/gopher-stress.log
```

## Reset

To start fresh, stop the server and delete the stress database:

```bash
rm ~/AngryGopher/stress/gopher.db
```

The demo-mode server recreates and seeds the database on startup.

## Ports

| Server  | Port |
|---------|------|
| Prod    | 9000 |
| Demo    | 9001 |
| Stress  | 9002 |
