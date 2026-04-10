// SSE (Server-Sent Events) endpoints:
//
// GET /gopher/sse/messages?channel_id=1&topic=hello
//   Streams hydrated message HTML fragments for initial page load.
//
// GET /gopher/sse/events
//   Live event stream. Bridges the event queue system to SSE.
//   When a new message arrives, renders it as HTML and pushes it.
package views

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const sseBatchSize = 100

// HandleSSEMessages streams messages for a channel+topic as SSE events.
func HandleSSEMessages(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	channelIDStr := r.URL.Query().Get("channel_id")
	topic := r.URL.Query().Get("topic")
	if channelIDStr == "" || topic == "" {
		http.Error(w, "Missing channel_id or topic", http.StatusBadRequest)
		return
	}

	var channelID int
	fmt.Sscanf(channelIDStr, "%d", &channelID)

	// SSE headers.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	const sseMaxMessages = 200

	// Get only the IDs we need (skip COUNT — it's expensive).
	idRows, err := DB.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = ? AND t.topic_name = ?
		ORDER BY m.id DESC LIMIT ?`, channelID, topic, sseMaxMessages)
	if err != nil {
		sseEvent(w, "error", "Failed to query messages")
		flusher.Flush()
		return
	}

	var allIDs []int
	for idRows.Next() {
		var id int
		idRows.Scan(&id)
		allIDs = append(allIDs, id)
	}
	idRows.Close()

	sseEvent(w, "count", fmt.Sprintf("%d", len(allIDs)))
	flusher.Flush()

	// Step 2: hydrate in batches and stream.
	for i := 0; i < len(allIDs); i += sseBatchSize {
		end := i + sseBatchSize
		if end > len(allIDs) {
			end = len(allIDs)
		}
		batch := allIDs[i:end]

		placeholders := make([]string, len(batch))
		args := make([]interface{}, len(batch))
		for j, id := range batch {
			placeholders[j] = "?"
			args[j] = id
		}

		query := fmt.Sprintf(`
			SELECT m.id, m.sender_id, u.full_name, mc.html, m.timestamp
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ","))

		rows, err := DB.Query(query, args...)
		if err != nil {
			sseEvent(w, "error", "Hydration failed")
			flusher.Flush()
			return
		}

		for rows.Next() {
			var msgID, senderID int
			var senderName, content string
			var timestamp int64
			rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp)

			t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
			fragment := fmt.Sprintf(
				`<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">`+
					`<b>%s</b> <span style="color:#888">%s</span>`+
					`<div style="padding:4px 0">%s</div></div>`,
				html.EscapeString(senderName),
				html.EscapeString(t),
				content)

			sseEvent(w, "message", fragment)
		}
		rows.Close()
		flusher.Flush()
	}

	sseEvent(w, "done", fmt.Sprintf("%d", len(allIDs)))
	flusher.Flush()
}

// HandleSSEEvents provides a live event stream for CRUD pages.
// The client opens an EventSource, and the server pushes new
// messages as rendered HTML fragments.
//
// GET /gopher/sse/events?channel_id=1&topic=hello
//
// Filters: channel_id and topic are optional. If provided, only
// messages matching the filter are pushed.
func HandleSSEEvents(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	filterChannelID, _ := strconv.Atoi(r.URL.Query().Get("channel_id"))
	filterTopic := r.URL.Query().Get("topic")

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	// Simple polling approach: check for new messages every 2 seconds.
	sseEvent(w, "connected", "ok")
	flusher.Flush()

	// Track the newest message ID we've seen.
	var maxMsgID int
	DB.QueryRow(`SELECT COALESCE(MAX(id), 0) FROM messages`).Scan(&maxMsgID)

	// Poll for new messages.
	ctx := r.Context()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Check for new messages since maxMsgID.
			query := `SELECT m.id, m.sender_id, u.full_name, mc.html, m.timestamp,
					m.channel_id, t.topic_name
				FROM messages m
				JOIN users u ON m.sender_id = u.id
				JOIN message_content mc ON m.content_id = mc.content_id
				JOIN topics t ON m.topic_id = t.topic_id
				WHERE m.id > ?`
			args := []interface{}{maxMsgID}

			if filterChannelID > 0 {
				query += ` AND m.channel_id = ?`
				args = append(args, filterChannelID)
			}
			if filterTopic != "" {
				query += ` AND t.topic_name = ?`
				args = append(args, filterTopic)
			}
			query += ` ORDER BY m.id ASC`

			rows, err := DB.Query(query, args...)
			if err != nil {
				continue
			}

			for rows.Next() {
				var msgID, senderID, chID int
				var senderName, content, topicName string
				var timestamp int64
				rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp, &chID, &topicName)

				ago := TimeAgo(timestamp)
				fragment := fmt.Sprintf(
					`<div class="new-msg" style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">`+
						`<b>%s</b> <span style="color:#888">%s</span>`+
						`<div style="padding:4px 0">%s</div></div>`,
					html.EscapeString(senderName),
					html.EscapeString(ago),
					content)

				// Include metadata as JSON for the client to decide placement.
				meta, _ := json.Marshal(map[string]interface{}{
					"id":         msgID,
					"channel_id": chID,
					"topic":      topicName,
				})
				sseEvent(w, "meta", string(meta))
				sseEvent(w, "message", fragment)
				flusher.Flush()

				if msgID > maxMsgID {
					maxMsgID = msgID
				}
			}
			rows.Close()
		}
	}
}

func sseEvent(w http.ResponseWriter, event, data string) {
	// SSE data lines can't have newlines — replace with SSE multi-line format.
	lines := strings.Split(data, "\n")
	fmt.Fprintf(w, "event: %s\n", event)
	for _, line := range lines {
		fmt.Fprintf(w, "data: %s\n", line)
	}
	fmt.Fprint(w, "\n")
}
