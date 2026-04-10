package views

import (
	"fmt"
	"html"
	"net/http"
	"strings"
	"time"

	"angry-gopher/search"
)

const hydrateLimit = 1000

// HandleSearch serves /gopher/search.
func HandleSearch(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Search")
	PageSubtitle(w, "Find any message by text, channel, topic, or sender. Trigram search finds URLs and code snippets that other chat apps miss.")

	// Channel picker.
	channelRows, err := DB.Query(`
		SELECT c.channel_id, c.name FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id AND s.user_id = ?
		ORDER BY c.name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load channels.</p>`)
		PageFooter(w)
		return
	}
	defer channelRows.Close()

	type channelInfo struct {
		id   int
		name string
	}
	var channels []channelInfo
	for channelRows.Next() {
		var ch channelInfo
		channelRows.Scan(&ch.id, &ch.name)
		channels = append(channels, ch)
	}

	params := search.ParseParams(r)

	// --- Filter form ---
	fmt.Fprint(w, `<form method="GET" action="/gopher/search" style="margin-bottom:16px">`)

	fmt.Fprint(w, `<label style="display:block;font-weight:bold;margin-bottom:4px">Channel</label>`)
	fmt.Fprint(w, `<select name="channel_id" style="margin-bottom:8px">`)
	fmt.Fprint(w, `<option value="">Any</option>`)
	for _, ch := range channels {
		sel := ""
		if ch.id == params.ChannelID {
			sel = " selected"
		}
		fmt.Fprintf(w, `<option value="%d"%s>#%s</option>`, ch.id, sel, html.EscapeString(ch.name))
	}
	fmt.Fprint(w, `</select><br>`)

	if params.ChannelID > 0 {
		fmt.Fprint(w, `<label style="display:block;font-weight:bold;margin-bottom:4px">Topic</label>`)
		fmt.Fprint(w, `<select name="topic_id" style="margin-bottom:8px">`)
		fmt.Fprint(w, `<option value="">Any</option>`)
		topicRows, _ := DB.Query(`SELECT topic_id, topic_name FROM topics WHERE channel_id = ? ORDER BY topic_name`, params.ChannelID)
		if topicRows != nil {
			for topicRows.Next() {
				var tid int
				var tname string
				topicRows.Scan(&tid, &tname)
				sel := ""
				if tid == params.TopicID {
					sel = " selected"
				}
				fmt.Fprintf(w, `<option value="%d"%s>%s</option>`, tid, sel, html.EscapeString(tname))
			}
			topicRows.Close()
		}
		fmt.Fprint(w, `</select><br>`)
	}

	senderID := 0
	if len(params.SenderIDs) == 1 {
		senderID = params.SenderIDs[0]
	}
	fmt.Fprint(w, `<label style="display:block;font-weight:bold;margin-bottom:4px">Sender</label>`)
	fmt.Fprint(w, `<select name="sender_id" style="margin-bottom:8px">`)
	fmt.Fprint(w, `<option value="">Any</option>`)
	userRows, _ := DB.Query(`SELECT id, full_name FROM users WHERE is_active = 1 ORDER BY full_name`)
	if userRows != nil {
		for userRows.Next() {
			var uid int
			var uname string
			userRows.Scan(&uid, &uname)
			sel := ""
			if uid == senderID {
				sel = " selected"
			}
			fmt.Fprintf(w, `<option value="%d"%s>%s</option>`, uid, sel, html.EscapeString(uname))
		}
		userRows.Close()
	}
	fmt.Fprint(w, `</select><br>`)

	fmt.Fprint(w, `<label style="display:block;font-weight:bold;margin-bottom:4px">Text (substring)</label>`)
	fmt.Fprintf(w, `<input type="text" name="text" value="%s" placeholder="e.g. http://foo.com" style="width:300px;padding:4px;margin-bottom:8px" autofocus><br>`,
		html.EscapeString(params.Text))

	fmt.Fprint(w, `<button type="submit">Search</button>`)
	fmt.Fprint(w, `</form>`)

	// --- Results ---
	hasFilter := params.ChannelID > 0 || params.TopicID > 0 || len(params.SenderIDs) > 0 || params.Text != ""
	if !hasFilter {
		fmt.Fprint(w, `<p class="muted">Pick at least one filter to search.</p>`)
		PageFooter(w)
		return
	}

	// Step 1: get ALL matching IDs (fast, index-only).
	// Override limit to get everything.
	unlimitedParams := params
	unlimitedParams.Limit = 1000000
	idQuery, idArgs := search.BuildQuery("m.id", "", userID, unlimitedParams)

	idRows, err := DB.Query(idQuery, idArgs...)
	if err != nil {
		fmt.Fprint(w, `<p>Search error.</p>`)
		PageFooter(w)
		return
	}

	var allIDs []int
	for idRows.Next() {
		var id int
		idRows.Scan(&id)
		allIDs = append(allIDs, id)
	}
	idRows.Close()

	totalCount := len(allIDs)
	fmt.Fprintf(w, `<p class="muted">%d messages found`, totalCount)

	// Step 2: hydrate the first 1000.
	showIDs := allIDs
	if len(showIDs) > hydrateLimit {
		showIDs = showIDs[:hydrateLimit]
		fmt.Fprintf(w, `, showing newest %d`, hydrateLimit)
	}
	fmt.Fprint(w, `</p>`)

	if len(showIDs) == 0 {
		fmt.Fprint(w, `<p class="muted">No messages found.</p>`)
	} else {
		placeholders := make([]string, len(showIDs))
		args := make([]interface{}, len(showIDs))
		for i, id := range showIDs {
			placeholders[i] = "?"
			args[i] = id
		}

		query := fmt.Sprintf(`
			SELECT m.id, m.sender_id, u.full_name, c.name, t.topic_name, mc.html, m.timestamp, m.channel_id
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN channels c ON m.channel_id = c.channel_id
			JOIN topics t ON m.topic_id = t.topic_id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ","))

		rows, err := DB.Query(query, args...)
		if err != nil {
			fmt.Fprint(w, `<p>Hydration error.</p>`)
			PageFooter(w)
			return
		}
		defer rows.Close()

		for rows.Next() {
			var msgID, msgSenderID, msgChannelID int
			var senderName, chName, topicName, content string
			var timestamp int64
			rows.Scan(&msgID, &msgSenderID, &senderName, &chName, &topicName, &content, &timestamp, &msgChannelID)

			t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
			fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> in %s > %s <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`,
				UserLink(msgSenderID, senderName),
				ChannelLink(msgChannelID, chName),
				html.EscapeString(topicName),
				html.EscapeString(t),
				content)
		}
	}

	PageFooter(w)
}
