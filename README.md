# Angry Gopher

A lightweight Zulip-compatible server backed by SQLite. Serves the
Zulip API subset that [Angry Cat](https://github.com/anthropics/angry-cat)
needs, fully standalone with no upstream Zulip connection.

## Quick start

    go build -o gopher-server .
    ./gopher-server

Listens on port 9000. Admin UI at http://localhost:9000/admin/.

The database is recreated fresh on every restart with 4 seeded users,
3 channels, and a welcome message.

## Supported endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | /api/v1/register | Register an event queue |
| GET | /api/v1/events | Long-poll for events (heartbeat after 50s) |
| GET | /api/v1/users | List all users |
| GET | /api/v1/users/me/subscriptions | Channels the authenticated user is subscribed to |
| GET | /api/v1/messages | Fetch messages (supports anchor + num_before) |
| POST | /api/v1/messages | Send a message (markdown rendered to HTML via goldmark) |
| POST | /api/v1/messages/flags | Update flags (read/unread, starred) |
| POST | /api/v1/user_uploads | Upload a file (stored in ~/AngryGopherImages) |
| GET | /api/v1/user_uploads/{id}/{file} | Get temporary URL for an upload |
| GET | /user_uploads/{id}/{file} | Serve an uploaded file |

## Not yet supported

These endpoints are used by Angry Cat but not yet implemented:

| Method | Endpoint | Description |
|--------|----------|-------------|
| PATCH | /api/v1/messages/{id} | Edit a message |
| POST | /api/v1/messages/{id}/reactions | Add a reaction |
| DELETE | /api/v1/messages/{id}/reactions | Remove a reaction |
| PATCH | /api/v1/streams/{id} | Update stream description |

## Authentication

All API requests use HTTP Basic auth: `base64(email:api_key)`.

Seeded users for development:

| Email | API Key | Name |
|-------|---------|------|
| steve@example.com | steve-api-key | Steve Howell |
| apoorva@example.com | apoorva-api-key | Apoorva Pendse |
| claude@example.com | claude-api-key | Claude |
| joe@example.com | joe-api-key | Joe Random |

## Channels

| ID | Name | Visibility | Subscribers |
|----|------|------------|-------------|
| 1 | Angry Cat | Private | Steve, Apoorva, Claude |
| 2 | Angry Gopher | Private | Steve, Apoorva, Claude |
| 3 | ChitChat | Public | All four users |

## Testing with Angry Cat

In the Angry Cat repo, navigate to `http://localhost:8000/gopher` and
log in with one of the credentials above. Angry Cat stores credentials
per realm in localStorage, so you can switch between Gopher and the
real Zulip server at `/mac`.

Use `restart.sh` to rebuild Angry Gopher, restart both servers, and
wait for readiness:

    ./restart.sh
