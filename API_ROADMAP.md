# Angry Gopher API Roadmap

Status key: **DONE** = endpoint is implemented with the most important
details working. Blank = not yet started.

Based on the [Zulip REST API table of contents](https://zulip.com/api/).

---

## Messages

| Status | Endpoint |
|--------|----------|
| DONE | Send a message |
| DONE | Upload a file |
| DONE | Edit a message |
| | Delete a message |
| DONE | Get messages |
| | Construct a narrow |
| DONE | Add an emoji reaction |
| DONE | Remove an emoji reaction |
| | Render a message |
| | Fetch a single message |
| | Check if messages match a narrow |
| | Get a message's edit history |
| DONE | Update personal message flags |
| | Update personal message flags for narrow |
| | Mark all messages as read |
| | Mark messages in a channel as read |
| | Mark messages in a topic as read |
| | Get a message's read receipts |
| DONE | Get temporary URL for an uploaded file |
| | Check thumbnail status |
| | Report a message |

## Scheduled messages — N/A (see DECISIONS.md)

## Message reminders

| Status | Endpoint |
|--------|----------|
| | Create a message reminder |
| | Get reminders |
| | Delete a reminder |

## Drafts

| Status | Endpoint |
|--------|----------|
| | Get drafts |
| | Create drafts |
| | Edit a draft |
| | Delete a draft |
| | Get all saved snippets |
| | Create a saved snippet |
| | Edit a saved snippet |
| | Delete a saved snippet |

## Navigation views

| Status | Endpoint |
|--------|----------|
| | Get all navigation views |
| | Add a navigation view |
| | Update the navigation view |
| | Remove a navigation view |

## Channels

| Status | Endpoint |
|--------|----------|
| DONE | Get subscribed channels |
| | Subscribe to a channel |
| | Unsubscribe from a channel |
| | Get subscription status |
| | Get channel subscribers |
| | Get a user's subscribed channels |
| | Update a subscription setting |
| | Bulk update subscription settings |
| | Get all channels |
| | Get a channel by ID |
| | Get channel ID |
| DONE | Create a channel |
| DONE | Update a channel |
| | Archive a channel |
| | Get channel's email address |
| | Get topics in a channel |
| | Topic muting |
| | Update personal preferences for a topic |
| | Delete a topic |
| | Add a default channel |
| | Remove a default channel |
| N/A | Channel folders (see DECISIONS.md) |

## Users

| Status | Endpoint |
|--------|----------|
| | Get a user |
| | Get a user by email |
| | Get own user |
| DONE | Get users |
| | Create a user |
| | Update a user |
| | Update a user by email |
| | Deactivate a user |
| | Deactivate own user |
| | Reactivate a user |
| | Get a user's status |
| | Update your status |
| | Update user status |
| | Update your profile data |
| | Remove your profile data |
| | Set "typing" status |
| | Set "typing" status for message editing |
| | Get a user's presence |
| DONE | Get presence of all users |
| DONE | Update your presence |
| | Get attachments |
| | Delete an attachment |
| DONE | Update settings |
| N/A | User groups (see DECISIONS.md) |
| | Mute a user |
| | Unmute a user |
| | Get all alert words |
| | Add alert words |
| | Remove alert words |
| | Regenerate your API key |
| | Get a bot's API key |
| | Regenerate a bot's API key |

## Invitations

| Status | Endpoint |
|--------|----------|
| | Get all invitations |
| DONE | Send invitations (Gopher-only: POST /gopher/invites) |
| | Create a reusable invitation link |
| | Resend an email invitation |
| | Revoke an email invitation |
| | Revoke a reusable invitation link |

## Server & organizations

| Status | Endpoint |
|--------|----------|
| DONE | Get server settings |
| | Get linkifiers |
| | Add a linkifier |
| | Update a linkifier |
| | Remove a linkifier |
| | Reorder linkifiers |
| | Add a code playground |
| | Remove a code playground |
| | Get all custom emoji |
| | Upload custom emoji |
| | Deactivate custom emoji |
| | Get all custom profile fields |
| | Reorder custom profile fields |
| | Create a custom profile field |
| | Update realm-level defaults of user settings |
| | Get allowed domains |
| | Add an allowed domain |
| | Update an allowed domain |
| | Remove an allowed domain |
| | Get all data exports |
| | Create a data export |
| | Get data export consent state |
| | Test welcome bot custom message |

## Real-time events

| Status | Endpoint |
|--------|----------|
| DONE | Register an event queue |
| DONE | Get events from an event queue |
| DONE | Delete an event queue |

## Specialty endpoints

| Status | Endpoint |
|--------|----------|
| | Fetch an API key (production) |
| | Fetch an API key (development only) |
| | List users (development only) |
| | Register a logged-in device |
| | Remove a registered device |
| | Send a test notification to mobile device(s) |
| | Add an APNs device token |
| | Remove an APNs device token |
| | Add an FCM registration token |
| | Remove an FCM registration token |
| | Create BigBlueButton video call |
| | Outgoing webhook payloads |

---

## Gopher-only endpoints (not in Zulip API)

| Status | Endpoint |
|--------|----------|
| DONE | GET/PUT /api/v1/buddies (buddy list) |
| DONE | POST /gopher/webhooks/github (incoming webhook) |
| DONE | GET /gopher/version |
| DONE | POST /gopher/invites (create invite) |
| DONE | POST /gopher/invites/redeem |
| DONE | POST /gopher/games (create game) |
| DONE | GET /gopher/games (list games) |
| DONE | POST /gopher/games/{id}/join |
| DONE | POST /gopher/games/{id}/events |
| DONE | GET /gopher/games/{id}/events (long-poll) |

---

## Handler patterns

Every PATCH (update) handler in Angry Gopher follows this
standard sequence. New endpoints should match the pattern
so the codebase stays consistent and auditable.

```
1. Method check       — if r.Method != http.MethodPatch { ... }
2. Authenticate       — userID := auth.Authenticate(r)
                        if userID == 0 { respond.Error(w, "Unauthorized"); return }
3. Parse path params  — e.g. respond.PathSegmentInt(r.URL.Path, 4)
                        (skip for endpoints like /settings that have no ID)
4. Access check       — e.g. channels.CanAccess(userID, channelID)
                        (skip for self-only endpoints like /settings)
5. Parse + validate   — r.FormValue("field"), strings.TrimSpace,
                        reject empty with respond.Error
6. DB update          — use a transaction if touching multiple tables,
                        plain Exec for single-table updates
7. Log                — log.Printf("[api] Edited X %d", id)
8. Emit event         — events.PushFiltered (channel-scoped) or
                        events.PushToAll (global, e.g. user changes)
                        Match the Zulip event type+op shape.
9. Respond            — respond.Success(w, data)
```

Auth error message is always "Unauthorized" (not "Authentication
required" or other variants). Error messages for DB failures
use "Failed to update X" without leaking the Go error string.
User-facing text fields (names, descriptions) are TrimSpace'd
before validation. Message content is NOT trimmed (whitespace
may be intentional in code blocks).

---

## Summary

**DONE:** 22 endpoints (Messages: 7, Channels: 3, Users: 4,
Server: 1, Invitations: 1, Real-time events: 3, Gopher-only: 10)

**N/A:** Scheduled messages (see DECISIONS.md)

**Remaining:** ~125 Zulip endpoints, most of which are low
priority or N/A for Angry Gopher's current scope.
