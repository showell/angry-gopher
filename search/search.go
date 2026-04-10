// Package search provides the message search API.
//
//   GET /api/v1/search?channel_id=1&topic_id=5&sender_id=3&before=1000&limit=50
//
// All parameters are optional. Returns lightweight ID tuples —
// no content, no user names. The client hydrates separately.
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

const DefaultLimit = 50
const MaxLimit = 200

// Params holds the parsed search filters.
type Params struct {
	ChannelID int
	TopicID   int
	SenderIDs []int
	Text      string // trigram full-text search
	Before    int    // cursor: messages with id < before
	Limit     int
}

// ParseParams extracts search parameters from the request.
func ParseParams(r *http.Request) Params {
	p := Params{
		Limit: DefaultLimit,
	}

	if v := r.URL.Query().Get("channel_id"); v != "" {
		p.ChannelID, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("topic_id"); v != "" {
		p.TopicID, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("sender_id"); v != "" {
		id, _ := strconv.Atoi(v)
		if id > 0 {
			p.SenderIDs = []int{id}
		}
	}
	if v := r.URL.Query().Get("sender_ids"); v != "" {
		for _, s := range strings.Split(v, ",") {
			id, _ := strconv.Atoi(strings.TrimSpace(s))
			if id > 0 {
				p.SenderIDs = append(p.SenderIDs, id)
			}
		}
	}
	if v := r.URL.Query().Get("text"); v != "" {
		p.Text = strings.TrimSpace(v)
	}
	if v := r.URL.Query().Get("before"); v != "" {
		p.Before, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		p.Limit, _ = strconv.Atoi(v)
	}
	if p.Limit <= 0 || p.Limit > MaxLimit {
		p.Limit = DefaultLimit
	}

	return p
}

// BuildQuery constructs a SQL query for the given columns and filters.
// The columns string is inserted into SELECT. The joins string is
// appended after "FROM messages m" — use it for content/user joins
// in the HTML view, or leave empty for the ID-only API.
func BuildQuery(columns, joins string, userID int, p Params) (string, []interface{}) {
	conditions := []string{`m.channel_id IN (
		SELECT channel_id FROM channels WHERE invite_only = 0
		UNION
		SELECT channel_id FROM subscriptions WHERE user_id = ?
	)`}
	args := []interface{}{userID}

	if p.ChannelID > 0 {
		conditions = append(conditions, "m.channel_id = ?")
		args = append(args, p.ChannelID)
	}
	if p.TopicID > 0 {
		conditions = append(conditions, "m.topic_id = ?")
		args = append(args, p.TopicID)
	}
	if len(p.SenderIDs) == 1 {
		conditions = append(conditions, "m.sender_id = ?")
		args = append(args, p.SenderIDs[0])
	} else if len(p.SenderIDs) > 1 {
		placeholders := make([]string, len(p.SenderIDs))
		for i, id := range p.SenderIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, fmt.Sprintf("m.sender_id IN (%s)", strings.Join(placeholders, ",")))
	}
	if p.Text != "" {
		// Join FTS table via content_id. The MATCH uses trigram
		// tokenization so any 3+ character substring works,
		// including URLs and code.
		joins += ` JOIN message_fts fts ON fts.content_id = m.content_id`
		conditions = append(conditions, "fts.content MATCH ?")
		args = append(args, `"`+p.Text+`"`)
	}
	if p.Before > 0 {
		conditions = append(conditions, "m.id < ?")
		args = append(args, p.Before)
	}

	query := fmt.Sprintf(
		`SELECT %s FROM messages m %s WHERE %s ORDER BY m.id DESC LIMIT ?`,
		columns, joins, strings.Join(conditions, " AND "))
	args = append(args, p.Limit)

	return query, args
}

// HandleHydrate handles POST /api/v1/hydrate.
// Accepts {"message_ids": [1, 2, 3]} and returns full content
// for each message. Both markdown and HTML are included.
func HandleHydrate(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	r.ParseForm()
	idsJSON := r.FormValue("message_ids")
	if idsJSON == "" {
		respond.Error(w, "Missing required param: message_ids")
		return
	}

	// Parse the ID list.
	var ids []int
	for _, s := range strings.Split(strings.Trim(idsJSON, "[]"), ",") {
		id, _ := strconv.Atoi(strings.TrimSpace(s))
		if id > 0 {
			ids = append(ids, id)
		}
	}

	if len(ids) == 0 {
		respond.Success(w, map[string]interface{}{"messages": []interface{}{}})
		return
	}
	if len(ids) > 10000 {
		respond.Error(w, "Too many IDs (max 10000)")
		return
	}

	placeholders := make([]string, len(ids))
	args := make([]interface{}, len(ids))
	for i, id := range ids {
		placeholders[i] = "?"
		args[i] = id
	}

	query := fmt.Sprintf(`
		SELECT m.id, m.content_id, mc.markdown, mc.html, m.sender_id, m.channel_id,
			m.topic_id, m.timestamp
		FROM messages m
		JOIN message_content mc ON m.content_id = mc.content_id
		WHERE m.id IN (%s)
		ORDER BY m.id`, strings.Join(placeholders, ","))

	rows, err := DB.Query(query, args...)
	if err != nil {
		respond.Error(w, "Hydration query failed")
		return
	}
	defer rows.Close()

	var messages []map[string]interface{}
	for rows.Next() {
		var id, contentID, senderID, channelID, topicID int
		var markdown, html string
		var timestamp int64
		rows.Scan(&id, &contentID, &markdown, &html, &senderID, &channelID, &topicID, &timestamp)
		messages = append(messages, map[string]interface{}{
			"id":         id,
			"content_id": contentID,
			"markdown":   markdown,
			"html":       html,
			"sender_id":  senderID,
			"channel_id": channelID,
			"topic_id":   topicID,
			"timestamp":  timestamp,
		})
	}

	respond.Success(w, map[string]interface{}{"messages": messages})
}

// HandleSearch handles GET /api/v1/search.
func HandleSearch(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	params := ParseParams(r)
	columns := "m.id, m.content_id, m.channel_id, m.topic_id, t.topic_name, m.sender_id, m.timestamp"
	joins := "JOIN topics t ON m.topic_id = t.topic_id"
	query, args := BuildQuery(columns, joins, userID, params)

	rows, err := DB.Query(query, args...)
	if err != nil {
		respond.Error(w, "Search query failed")
		return
	}
	defer rows.Close()

	var messages []map[string]interface{}
	for rows.Next() {
		var id, contentID, channelID, topicID, senderID int
		var topicName string
		var timestamp int64
		rows.Scan(&id, &contentID, &channelID, &topicID, &topicName, &senderID, &timestamp)
		messages = append(messages, map[string]interface{}{
			"id":         id,
			"content_id": contentID,
			"channel_id": channelID,
			"topic_id":   topicID,
			"topic_name": topicName,
			"sender_id":  senderID,
			"timestamp":  timestamp,
		})
	}

	respond.Success(w, map[string]interface{}{"messages": messages})
}
