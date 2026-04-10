// Package webhooks handles incoming webhook integrations.
//
// GitHub webhook: POST /gopher/webhooks/github?api_key=KEY&channel_id=N
//
// Handles push, pull_request, and issues events. Produces HTML
// directly — no markdown rendering pass.
package webhooks

import (
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"

	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/messages"
	"angry-gopher/respond"
)

// webhookUserID is the user ID that webhook messages are sent as.
// Set by main to avoid a DB dependency in this package.
var WebhookUserID int

func HandleGitHub(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		respond.Error(w, "Method not allowed")
		return
	}

	apiKey := r.URL.Query().Get("api_key")
	channelIDStr := r.URL.Query().Get("channel_id")
	channelID, _ := strconv.Atoi(channelIDStr)

	if apiKey == "" || channelID == 0 {
		respond.Error(w, "Missing required params: api_key, channel_id")
		return
	}

	if !authenticateWebhook(apiKey) {
		respond.Error(w, "Invalid API key")
		return
	}

	if !channels.ChannelExists(channelID) {
		respond.Error(w, "Unknown channel_id")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		respond.Error(w, "Failed to read request body")
		return
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		respond.Error(w, "Invalid JSON payload")
		return
	}

	eventType := r.Header.Get("X-GitHub-Event")
	if eventType == "" {
		respond.Error(w, "Missing X-GitHub-Event header")
		return
	}

	topic, htmlContent, ok := formatGitHubEvent(eventType, payload)
	if !ok {
		// Unhandled event type — acknowledge silently.
		respond.Success(w, nil)
		return
	}

	// Plain text fallback for the markdown column.
	plainText := stripHTMLForMarkdown(htmlContent)

	senderID := WebhookUserID
	if senderID == 0 {
		senderID = 1 // fallback
	}

	msgID, err := messages.SendMessageHTML(senderID, channelID, topic, plainText, htmlContent)
	if err != nil {
		log.Printf("[webhook] Failed to send message: %v", err)
		respond.Error(w, "Failed to send message")
		return
	}

	// Push event to users who can see this channel.
	events.PushFiltered(map[string]interface{}{
		"type": "message",
		"message": map[string]interface{}{
			"id": msgID,
		},
	}, func(userID int) bool {
		return channels.CanAccess(userID, channelID)
	})

	log.Printf("[webhook] GitHub %s → channel %d, topic %q", eventType, channelID, topic)
	respond.Success(w, map[string]interface{}{"id": msgID})
}

// authenticateWebhook checks the API key against any admin user.
func authenticateWebhook(apiKey string) bool {
	var count int
	messages.DB.QueryRow(
		`SELECT COUNT(*) FROM users WHERE api_key = ? AND is_admin = 1`,
		apiKey,
	).Scan(&count)
	return count > 0
}

// --- Event formatters ---

func formatGitHubEvent(eventType string, payload map[string]interface{}) (topic, html string, ok bool) {
	repo := repoName(payload)

	switch eventType {
	case "push":
		return formatPush(repo, payload)
	case "pull_request":
		return formatPullRequest(repo, payload)
	case "issues":
		return formatIssue(repo, payload)
	default:
		return "", "", false
	}
}

func formatPush(repo string, payload map[string]interface{}) (string, string, bool) {
	ref, _ := payload["ref"].(string)
	branch := strings.TrimPrefix(ref, "refs/heads/")
	pusher := jsonStr(payload, "pusher", "name")
	compareURL, _ := payload["compare"].(string)

	commits, _ := payload["commits"].([]interface{})
	if len(commits) == 0 {
		return "", "", false
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("<b>%s</b> pushed %d commit(s) to <b>%s</b>",
		html.EscapeString(pusher),
		len(commits),
		html.EscapeString(branch)))

	if compareURL != "" {
		b.WriteString(fmt.Sprintf(` (<a href="%s">compare</a>)`, html.EscapeString(compareURL)))
	}

	b.WriteString("<ul>")
	limit := len(commits)
	if limit > 5 {
		limit = 5
	}
	for i := 0; i < limit; i++ {
		c, _ := commits[i].(map[string]interface{})
		sha, _ := c["id"].(string)
		msg, _ := c["message"].(string)
		url, _ := c["url"].(string)
		// First line only.
		if idx := strings.IndexByte(msg, '\n'); idx > 0 {
			msg = msg[:idx]
		}
		shortSHA := sha
		if len(sha) > 7 {
			shortSHA = sha[:7]
		}
		b.WriteString(fmt.Sprintf(`<li><a href="%s"><code>%s</code></a> %s</li>`,
			html.EscapeString(url),
			html.EscapeString(shortSHA),
			html.EscapeString(msg)))
	}
	if len(commits) > 5 {
		b.WriteString(fmt.Sprintf("<li>… and %d more</li>", len(commits)-5))
	}
	b.WriteString("</ul>")

	topic := fmt.Sprintf("%s / %s", repo, branch)
	return topic, b.String(), true
}

func formatPullRequest(repo string, payload map[string]interface{}) (string, string, bool) {
	action, _ := payload["action"].(string)
	pr, _ := payload["pull_request"].(map[string]interface{})
	if pr == nil {
		return "", "", false
	}

	number := int(jsonFloat(pr, "number"))
	title, _ := pr["title"].(string)
	url, _ := pr["html_url"].(string)
	user := jsonStr(pr, "user", "login")
	merged, _ := pr["merged"].(bool)

	// Refine "closed" to "merged" when applicable.
	if action == "closed" && merged {
		action = "merged"
	}

	switch action {
	case "opened", "closed", "merged", "reopened":
		// These are the actions we care about.
	default:
		return "", "", false
	}

	htmlContent := fmt.Sprintf(`<b>%s</b> %s PR <a href="%s">#%d</a>: %s`,
		html.EscapeString(user),
		html.EscapeString(action),
		html.EscapeString(url),
		number,
		html.EscapeString(title))

	topic := fmt.Sprintf("%s / PR #%d %s", repo, number, title)
	if len(topic) > 60 {
		topic = topic[:57] + "..."
	}
	return topic, htmlContent, true
}

func formatIssue(repo string, payload map[string]interface{}) (string, string, bool) {
	action, _ := payload["action"].(string)
	issue, _ := payload["issue"].(map[string]interface{})
	if issue == nil {
		return "", "", false
	}

	number := int(jsonFloat(issue, "number"))
	title, _ := issue["title"].(string)
	url, _ := issue["html_url"].(string)
	user := jsonStr(issue, "user", "login")

	switch action {
	case "opened", "closed", "reopened":
		// These are the actions we care about.
	default:
		return "", "", false
	}

	htmlContent := fmt.Sprintf(`<b>%s</b> %s issue <a href="%s">#%d</a>: %s`,
		html.EscapeString(user),
		html.EscapeString(action),
		html.EscapeString(url),
		number,
		html.EscapeString(title))

	topic := fmt.Sprintf("%s / issue #%d %s", repo, number, title)
	if len(topic) > 60 {
		topic = topic[:57] + "..."
	}
	return topic, htmlContent, true
}

// --- Helpers ---

func repoName(payload map[string]interface{}) string {
	repo, _ := payload["repository"].(map[string]interface{})
	name, _ := repo["full_name"].(string)
	return name
}

func jsonStr(obj map[string]interface{}, keys ...string) string {
	var current interface{} = obj
	for _, k := range keys {
		m, ok := current.(map[string]interface{})
		if !ok {
			return ""
		}
		current = m[k]
	}
	s, _ := current.(string)
	return s
}

func jsonFloat(obj map[string]interface{}, key string) float64 {
	v, _ := obj[key].(float64)
	return v
}

// stripHTMLForMarkdown produces a plain-text approximation for the
// markdown column. Webhook messages aren't meant to be edited, but
// we store something readable as a fallback.
func stripHTMLForMarkdown(s string) string {
	// Very basic: remove tags, decode entities.
	s = strings.ReplaceAll(s, "<ul>", "\n")
	s = strings.ReplaceAll(s, "</ul>", "")
	s = strings.ReplaceAll(s, "<li>", "- ")
	s = strings.ReplaceAll(s, "</li>", "\n")
	s = strings.ReplaceAll(s, "<b>", "**")
	s = strings.ReplaceAll(s, "</b>", "**")
	s = strings.ReplaceAll(s, "<code>", "`")
	s = strings.ReplaceAll(s, "</code>", "`")
	// Strip remaining tags.
	var b strings.Builder
	inTag := false
	for _, r := range s {
		if r == '<' {
			inTag = true
			continue
		}
		if r == '>' {
			inTag = false
			continue
		}
		if !inTag {
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
