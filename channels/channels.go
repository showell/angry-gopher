// Package channels handles subscription listing and channel updates.
package channels

import (
	"database/sql"
	"encoding/json"
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
