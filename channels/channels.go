// Package channels handles subscription listing and channel updates.
package channels

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// RenderMarkdown is set by main to avoid a circular dependency
// with the markdown package.
var RenderMarkdown func(string) string

// CanAccess returns true if the user can see the given channel.
// Public channels are visible to everyone; private channels require
// a subscription.
// ChannelExists returns true if the given channel ID exists.
func ChannelExists(channelID int) bool {
	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM channels WHERE channel_id = ?`, channelID).Scan(&count)
	return count > 0
}

func CanAccess(userID, channelID int) bool {
	var inviteOnly int
	err := DB.QueryRow(`SELECT invite_only FROM channels WHERE channel_id = ?`, channelID).Scan(&inviteOnly)
	if err != nil {
		return false
	}
	if inviteOnly == 0 {
		return true
	}
	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM subscriptions WHERE user_id = ? AND channel_id = ?`,
		userID, channelID).Scan(&count)
	return count > 0
}

// CanAccessMessage returns true if the user can see the channel that
// contains the given message.
func CanAccessMessage(userID, messageID int) bool {
	var channelID int
	err := DB.QueryRow(`SELECT channel_id FROM messages WHERE id = ?`, messageID).Scan(&channelID)
	if err != nil {
		return false
	}
	return CanAccess(userID, channelID)
}

// HandleSubscriptions handles GET /api/v1/users/me/subscriptions.
func HandleSubscriptions(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name,
		       COALESCE(cd.markdown, ''), COALESCE(cd.html, ''),
		       c.channel_weekly_traffic, c.invite_only
		FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id
		LEFT JOIN channel_descriptions cd ON c.channel_id = cd.channel_id
		WHERE s.user_id = ?`, userID)
	if err != nil {
		respond.Error(w, "Failed to query subscriptions")
		return
	}
	defer rows.Close()

	var subs []map[string]interface{}
	for rows.Next() {
		var channelID, traffic, inviteOnly int
		var name, desc, renderedDesc string
		rows.Scan(&channelID, &name, &desc, &renderedDesc, &traffic, &inviteOnly)
		subs = append(subs, map[string]interface{}{
			"stream_id":             channelID,
			"name":                  name,
			"description":           desc,
			"rendered_description":  renderedDesc,
			"stream_weekly_traffic": traffic,
			"invite_only":           inviteOnly == 1,
		})
	}

	respond.Success(w, map[string]interface{}{"subscriptions": subs})
}

// HandleCreateChannel handles POST /api/v1/users/me/subscriptions.
// Creates new channels and subscribes the specified principals.
func HandleCreateChannel(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	// Parse subscriptions: [{name, description}]
	type subInfo struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	var subs []subInfo
	if err := json.Unmarshal([]byte(r.FormValue("subscriptions")), &subs); err != nil || len(subs) == 0 {
		respond.Error(w, "Invalid or missing subscriptions parameter")
		return
	}

	inviteOnly := r.FormValue("invite_only") == "true"

	// Parse principals (user IDs to subscribe).
	var principals []int
	if p := r.FormValue("principals"); p != "" {
		json.Unmarshal([]byte(p), &principals)
	}
	if len(principals) == 0 {
		principals = []int{userID}
	}

	inviteOnlyInt := 0
	if inviteOnly {
		inviteOnlyInt = 1
	}

	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "Database error")
		return
	}
	defer tx.Rollback()

	type createdChannel struct {
		id       int64
		name     string
		desc     string
		rendered string
	}
	var created []createdChannel

	for _, sub := range subs {
		if sub.Name == "" {
			continue
		}

		var existing int
		tx.QueryRow(`SELECT COUNT(*) FROM channels WHERE name = ?`, sub.Name).Scan(&existing)
		if existing > 0 {
			continue
		}

		renderedDesc := ""
		if sub.Description != "" {
			renderedDesc = RenderMarkdown(sub.Description)
		}

		result, err := tx.Exec(
			`INSERT INTO channels (name, invite_only) VALUES (?, ?)`,
			sub.Name, inviteOnlyInt,
		)
		if err != nil {
			respond.Error(w, "Failed to create channel")
			return
		}

		channelID, _ := result.LastInsertId()

		if sub.Description != "" {
			tx.Exec(
				`INSERT INTO channel_descriptions (channel_id, markdown, html) VALUES (?, ?, ?)`,
				channelID, sub.Description, renderedDesc)
		}

		for _, uid := range principals {
			tx.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`,
				uid, channelID)
		}

		created = append(created, createdChannel{channelID, sub.Name, sub.Description, renderedDesc})
	}

	if err := tx.Commit(); err != nil {
		respond.Error(w, "Database error")
		return
	}

	// Push events after commit — only for successfully created channels.
	var createdNames []string
	for _, ch := range created {
		log.Printf("[api] Created channel %d: %s (invite_only=%v)", ch.id, ch.name, inviteOnly)
		createdNames = append(createdNames, ch.name)

		principalSet := make(map[int]bool)
		for _, uid := range principals {
			principalSet[uid] = true
		}
		events.PushFiltered(map[string]interface{}{
			"type": "subscription",
			"op":   "add",
			"subscriptions": []map[string]interface{}{
				{
					"stream_id":            ch.id,
					"name":                 ch.name,
					"description":          ch.desc,
					"rendered_description": ch.rendered,
					"stream_weekly_traffic": 0,
				},
			},
		}, func(uid int) bool {
			return principalSet[uid]
		})
	}

	respond.Success(w, map[string]interface{}{
		"already_subscribed": map[string]interface{}{},
		"subscribed":         createdNames,
	})
}

// HandleUpdateChannel handles PATCH /api/v1/streams/{id}.
func HandleUpdateChannel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPatch {
		respond.Error(w, "Method not allowed")
		return
	}

	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	channelID := respond.PathSegmentInt(r.URL.Path, 4)
	if channelID == 0 {
		respond.Error(w, "Invalid channel ID")
		return
	}

	if !CanAccess(userID, channelID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	description := strings.TrimSpace(r.FormValue("description"))
	if description == "" {
		respond.Error(w, "Missing required parameter: description")
		return
	}

	html := RenderMarkdown(description)

	// Upsert into channel_descriptions: INSERT if no row exists
	// yet for this channel, UPDATE if one already does.
	_, err := DB.Exec(
		`INSERT INTO channel_descriptions (channel_id, markdown, html)
		 VALUES (?, ?, ?)
		 ON CONFLICT(channel_id) DO UPDATE SET markdown = ?, html = ?`,
		channelID, description, html, description, html,
	)
	if err != nil {
		respond.Error(w, "Failed to update channel description")
		return
	}

	log.Printf("[api] Updated description for channel %d", channelID)

	events.PushFiltered(map[string]interface{}{
		"type":                 "stream",
		"op":                   "update",
		"property":             "description",
		"stream_id":            channelID,
		"value":                description,
		"rendered_description": html,
	}, func(uid int) bool {
		return CanAccess(uid, channelID)
	})

	respond.Success(w, nil)
}

// HandleGetTopics handles GET /api/v1/streams/{id}/topics.
func HandleGetTopics(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	channelID := respond.PathSegmentInt(r.URL.Path, 4)
	if channelID == 0 {
		respond.Error(w, "Invalid channel ID")
		return
	}

	if !CanAccess(userID, channelID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	rows, err := DB.Query(`
		SELECT t.topic_name,
			(SELECT MAX(m.id) FROM messages m WHERE m.topic_id = t.topic_id) AS max_id
		FROM topics t
		WHERE t.channel_id = ?
		ORDER BY max_id DESC`, channelID)
	if err != nil {
		respond.Error(w, "Failed to query topics")
		return
	}
	defer rows.Close()

	var topics []map[string]interface{}
	for rows.Next() {
		var name string
		var maxID sql.NullInt64
		rows.Scan(&name, &maxID)
		t := map[string]interface{}{"name": name, "max_id": 0}
		if maxID.Valid {
			t["max_id"] = maxID.Int64
		}
		topics = append(topics, t)
	}

	respond.Success(w, map[string]interface{}{"topics": topics})
}

// HandleGetSubscribers handles GET /api/v1/streams/{id}/subscribers.
func HandleGetSubscribers(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	channelID := respond.PathSegmentInt(r.URL.Path, 4)
	if channelID == 0 {
		respond.Error(w, "Invalid channel ID")
		return
	}

	if !CanAccess(userID, channelID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	rows, err := DB.Query(`
		SELECT u.id, u.full_name, u.email
		FROM users u
		JOIN subscriptions s ON u.id = s.user_id
		WHERE s.channel_id = ?
		ORDER BY u.full_name`, channelID)
	if err != nil {
		respond.Error(w, "Failed to query subscribers")
		return
	}
	defer rows.Close()

	var subs []map[string]interface{}
	for rows.Next() {
		var id int
		var name, email string
		rows.Scan(&id, &name, &email)
		subs = append(subs, map[string]interface{}{
			"user_id":   id,
			"full_name": name,
			"email":     email,
		})
	}

	respond.Success(w, map[string]interface{}{"subscribers": subs})
}

// HandleGetAllChannels handles GET /api/v1/streams.
func HandleGetAllChannels(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, c.invite_only,
			COALESCE(cd.markdown, ''), COALESCE(cd.html, ''),
			c.channel_weekly_traffic
		FROM channels c
		LEFT JOIN channel_descriptions cd ON c.channel_id = cd.channel_id
		ORDER BY c.name`)
	if err != nil {
		respond.Error(w, "Failed to query channels")
		return
	}
	defer rows.Close()

	var streams []map[string]interface{}
	for rows.Next() {
		var id, inviteOnly, traffic int
		var name, desc, renderedDesc string
		rows.Scan(&id, &name, &inviteOnly, &desc, &renderedDesc, &traffic)
		streams = append(streams, map[string]interface{}{
			"stream_id":             id,
			"name":                  name,
			"description":           desc,
			"rendered_description":  renderedDesc,
			"stream_weekly_traffic": traffic,
			"invite_only":           inviteOnly == 1,
		})
	}

	respond.Success(w, map[string]interface{}{"streams": streams})
}

// HandleSubscribe handles POST /api/v1/users/me/subscriptions/add.
func HandleSubscribe(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	r.ParseForm()
	channelIDStr := r.FormValue("channel_id")
	var channelID int
	if channelIDStr != "" {
		fmt.Sscanf(channelIDStr, "%d", &channelID)
	}
	if channelID == 0 {
		respond.Error(w, "Missing required param: channel_id")
		return
	}

	if !ChannelExists(channelID) {
		respond.Error(w, "Unknown channel")
		return
	}

	DB.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, userID, channelID)
	log.Printf("[api] User %d subscribed to channel %d", userID, channelID)
	respond.Success(w, nil)
}

// HandleUnsubscribe handles DELETE /api/v1/users/me/subscriptions.
func HandleUnsubscribe(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	respond.ParseFormBody(r)
	channelIDStr := r.FormValue("channel_id")
	var channelID int
	if channelIDStr != "" {
		fmt.Sscanf(channelIDStr, "%d", &channelID)
	}
	if channelID == 0 {
		respond.Error(w, "Missing required param: channel_id")
		return
	}

	DB.Exec(`DELETE FROM subscriptions WHERE user_id = ? AND channel_id = ?`, userID, channelID)
	log.Printf("[api] User %d unsubscribed from channel %d", userID, channelID)
	respond.Success(w, nil)
}

// HandleMuteTopic handles POST/DELETE /api/v1/users/me/muted_topics.
func HandleMuteTopic(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	if r.Method == "GET" {
		handleGetMutedTopics(w, userID)
		return
	}

	if r.Method == "DELETE" {
		respond.ParseFormBody(r)
	} else {
		r.ParseForm()
	}

	channelIDStr := r.FormValue("channel_id")
	topicName := r.FormValue("topic")
	var channelID int
	fmt.Sscanf(channelIDStr, "%d", &channelID)

	if channelID == 0 || topicName == "" {
		respond.Error(w, "Missing required params: channel_id, topic")
		return
	}

	if r.Method == "POST" {
		DB.Exec(`INSERT OR IGNORE INTO muted_topics (user_id, channel_id, topic_name) VALUES (?, ?, ?)`,
			userID, channelID, topicName)
		log.Printf("[api] User %d muted topic %q in channel %d", userID, topicName, channelID)
		respond.Success(w, nil)
	} else if r.Method == "DELETE" {
		DB.Exec(`DELETE FROM muted_topics WHERE user_id = ? AND channel_id = ? AND topic_name = ?`,
			userID, channelID, topicName)
		log.Printf("[api] User %d unmuted topic %q in channel %d", userID, topicName, channelID)
		respond.Success(w, nil)
	} else {
		respond.Error(w, "Method not allowed")
	}
}

func handleGetMutedTopics(w http.ResponseWriter, userID int) {
	rows, err := DB.Query(`
		SELECT mt.channel_id, c.name, mt.topic_name
		FROM muted_topics mt
		JOIN channels c ON mt.channel_id = c.channel_id
		WHERE mt.user_id = ?
		ORDER BY c.name, mt.topic_name`, userID)
	if err != nil {
		respond.Error(w, "Failed to query muted topics")
		return
	}
	defer rows.Close()

	var muted []map[string]interface{}
	for rows.Next() {
		var channelID int
		var channelName, topicName string
		rows.Scan(&channelID, &channelName, &topicName)
		muted = append(muted, map[string]interface{}{
			"channel_id":   channelID,
			"channel_name": channelName,
			"topic":        topicName,
		})
	}

	respond.Success(w, map[string]interface{}{"muted_topics": muted})
}
