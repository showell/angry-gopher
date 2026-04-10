// Package search provides the message search API.
//
//   GET /api/v1/search?channel_id=1&topic_id=5&sender_id=3&before=1000&limit=50
//
// All parameters are optional. Returns lightweight ID tuples —
// no content, no user names. The client hydrates separately.
//
// Response:
//   {
//     "result": "success",
//     "messages": [
//       {"id": 999, "content_id": 42, "channel_id": 1, "topic_id": 5, "sender_id": 3, "timestamp": 1712345678},
//       ...
//     ]
//   }
package search

import (
	"database/sql"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

var DB *sql.DB

const defaultLimit = 50
const maxLimit = 200

// HandleSearch handles GET /api/v1/search.
func HandleSearch(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	params := parseParams(r)

	query, args := buildQuery(userID, params)

	rows, err := DB.Query(query, args...)
	if err != nil {
		respond.Error(w, "Search query failed")
		return
	}
	defer rows.Close()

	var messages []map[string]interface{}
	for rows.Next() {
		var id, contentID, channelID, topicID, senderID int
		var timestamp int64
		rows.Scan(&id, &contentID, &channelID, &topicID, &senderID, &timestamp)
		messages = append(messages, map[string]interface{}{
			"id":         id,
			"content_id": contentID,
			"channel_id": channelID,
			"topic_id":   topicID,
			"sender_id":  senderID,
			"timestamp":  timestamp,
		})
	}

	respond.Success(w, map[string]interface{}{"messages": messages})
}

type searchParams struct {
	channelID int
	topicID   int
	senderIDs []int
	before    int // cursor: messages with id < before
	limit     int
}

func parseParams(r *http.Request) searchParams {
	p := searchParams{
		limit: defaultLimit,
	}

	if v := r.URL.Query().Get("channel_id"); v != "" {
		p.channelID, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("topic_id"); v != "" {
		p.topicID, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("sender_id"); v != "" {
		// Single sender.
		id, _ := strconv.Atoi(v)
		if id > 0 {
			p.senderIDs = []int{id}
		}
	}
	if v := r.URL.Query().Get("sender_ids"); v != "" {
		// Comma-separated list (for buddy filtering).
		for _, s := range strings.Split(v, ",") {
			id, _ := strconv.Atoi(strings.TrimSpace(s))
			if id > 0 {
				p.senderIDs = append(p.senderIDs, id)
			}
		}
	}
	if v := r.URL.Query().Get("before"); v != "" {
		p.before, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		p.limit, _ = strconv.Atoi(v)
	}
	if p.limit <= 0 || p.limit > maxLimit {
		p.limit = defaultLimit
	}

	return p
}

func buildQuery(userID int, p searchParams) (string, []interface{}) {
	// Access filter: only messages from channels the user can see.
	conditions := []string{`m.channel_id IN (
		SELECT channel_id FROM channels WHERE invite_only = 0
		UNION
		SELECT channel_id FROM subscriptions WHERE user_id = ?
	)`}
	args := []interface{}{userID}

	if p.channelID > 0 {
		conditions = append(conditions, "m.channel_id = ?")
		args = append(args, p.channelID)
	}
	if p.topicID > 0 {
		conditions = append(conditions, "m.topic_id = ?")
		args = append(args, p.topicID)
	}
	if len(p.senderIDs) == 1 {
		conditions = append(conditions, "m.sender_id = ?")
		args = append(args, p.senderIDs[0])
	} else if len(p.senderIDs) > 1 {
		placeholders := make([]string, len(p.senderIDs))
		for i, id := range p.senderIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, fmt.Sprintf("m.sender_id IN (%s)", strings.Join(placeholders, ",")))
	}
	if p.before > 0 {
		conditions = append(conditions, "m.id < ?")
		args = append(args, p.before)
	}

	query := fmt.Sprintf(
		`SELECT m.id, m.content_id, m.channel_id, m.topic_id, m.sender_id, m.timestamp
		 FROM messages m
		 WHERE %s
		 ORDER BY m.id DESC
		 LIMIT ?`,
		strings.Join(conditions, " AND "))
	args = append(args, p.limit)

	return query, args
}
