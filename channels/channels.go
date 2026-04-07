// Package channels handles subscription listing and channel updates.
package channels

import (
	"database/sql"
	"log"
	"net/http"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// RenderMarkdown is set by main to avoid a circular dependency
// with the markdown package.
var RenderMarkdown func(string) string

// HandleSubscriptions handles GET /api/v1/users/me/subscriptions.
func HandleSubscriptions(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, c.description, c.rendered_description,
		       c.channel_weekly_traffic, c.invite_only
		FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id
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

// HandleUpdateChannel handles PATCH /api/v1/streams/{id}.
func HandleUpdateChannel(w http.ResponseWriter, r *http.Request) {
	channelID := respond.PathSegmentInt(r.URL.Path, 4)
	if channelID == 0 {
		respond.Error(w, "Invalid channel ID")
		return
	}

	description := r.FormValue("description")
	if description == "" {
		respond.Error(w, "Missing required parameter: description")
		return
	}

	renderedDesc := RenderMarkdown(description)

	_, err := DB.Exec(
		`UPDATE channels SET description = ?, rendered_description = ? WHERE channel_id = ?`,
		description, renderedDesc, channelID,
	)
	if err != nil {
		respond.Error(w, "Failed to update channel")
		return
	}

	log.Printf("[api] Updated description for channel %d", channelID)

	events.PushToAll(map[string]interface{}{
		"type":                 "stream",
		"op":                   "update",
		"property":             "description",
		"stream_id":            channelID,
		"value":                description,
		"rendered_description": renderedDesc,
	})

	respond.Success(w, nil)
}
