// Package webhooks handles incoming webhook integrations.
//
// GitHub webhook: POST /gopher/webhooks/github?repo_id=N&api_key=KEY
//
// The repo_id maps to a row in github_repos, which stores the
// channel and optional default topic. Handles push, pull_request,
// and issues events. Produces HTML directly — no markdown pass.
package webhooks

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/messages"
	"angry-gopher/respond"
)

var DB *sql.DB

// WebhookUserID is the user ID that webhook messages are sent as.
var WebhookUserID int

// --- Repo config ---

type RepoConfig struct {
	ID           int    `json:"id"`
	Owner        string `json:"owner"`
	Name         string `json:"name"`
	ChannelID    int    `json:"channel_id"`
	DefaultTopic string `json:"default_topic"`
}

func lookupRepo(repoID int) (*RepoConfig, error) {
	var rc RepoConfig
	err := DB.QueryRow(
		`SELECT id, owner, name, channel_id, default_topic FROM github_repos WHERE id = ?`,
		repoID,
	).Scan(&rc.ID, &rc.Owner, &rc.Name, &rc.ChannelID, &rc.DefaultTopic)
	if err != nil {
		return nil, err
	}
	return &rc, nil
}

func lookupRepoByName(owner, name string) (*RepoConfig, error) {
	var rc RepoConfig
	err := DB.QueryRow(
		`SELECT id, owner, name, channel_id, default_topic FROM github_repos WHERE owner = ? AND name = ?`,
		owner, name,
	).Scan(&rc.ID, &rc.Owner, &rc.Name, &rc.ChannelID, &rc.DefaultTopic)
	if err != nil {
		return nil, err
	}
	return &rc, nil
}

// --- Repo CRUD: GET/POST /gopher/github/repos ---

func HandleRepos(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 || !auth.IsAdmin(userID) {
		respond.Error(w, "Admin access required")
		return
	}

	switch r.Method {
	case "GET":
		handleListRepos(w)
	case "POST":
		handleCreateRepo(w, r)
	case "DELETE":
		handleDeleteRepo(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func handleListRepos(w http.ResponseWriter) {
	rows, err := DB.Query(`
		SELECT gr.id, gr.owner, gr.name, gr.channel_id, gr.default_topic, c.name
		FROM github_repos gr
		JOIN channels c ON gr.channel_id = c.channel_id
		ORDER BY gr.owner, gr.name`)
	if err != nil {
		respond.Error(w, "Failed to query repos")
		return
	}
	defer rows.Close()

	var repos []map[string]interface{}
	for rows.Next() {
		var id, channelID int
		var owner, name, defaultTopic, channelName string
		rows.Scan(&id, &owner, &name, &channelID, &defaultTopic, &channelName)
		repos = append(repos, map[string]interface{}{
			"id":            id,
			"owner":         owner,
			"name":          name,
			"channel_id":    channelID,
			"channel_name":  channelName,
			"default_topic": defaultTopic,
		})
	}

	respond.Success(w, map[string]interface{}{"repos": repos})
}

func handleCreateRepo(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	owner := strings.TrimSpace(r.FormValue("owner"))
	name := strings.TrimSpace(r.FormValue("name"))
	channelIDStr := r.FormValue("channel_id")
	defaultTopic := strings.TrimSpace(r.FormValue("default_topic"))
	channelID, _ := strconv.Atoi(channelIDStr)

	if owner == "" || name == "" || channelID == 0 {
		respond.Error(w, "Missing required params: owner, name, channel_id")
		return
	}

	if !channels.ChannelExists(channelID) {
		respond.Error(w, "Unknown channel_id")
		return
	}

	result, err := DB.Exec(
		`INSERT OR REPLACE INTO github_repos (owner, name, channel_id, default_topic) VALUES (?, ?, ?, ?)`,
		owner, name, channelID, defaultTopic)
	if err != nil {
		respond.Error(w, "Failed to save repo config")
		return
	}
	id, _ := result.LastInsertId()

	log.Printf("[github] Configured repo %s/%s → channel %d (id=%d)", owner, name, channelID, id)
	respond.Success(w, map[string]interface{}{"id": id})
}

func handleDeleteRepo(w http.ResponseWriter, r *http.Request) {
	respond.ParseFormBody(r)
	idStr := r.FormValue("id")
	id, _ := strconv.Atoi(idStr)
	if id == 0 {
		respond.Error(w, "Missing required param: id")
		return
	}

	result, err := DB.Exec(`DELETE FROM github_repos WHERE id = ?`, id)
	if err != nil {
		respond.Error(w, "Failed to delete repo")
		return
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		respond.Error(w, "Repo not found")
		return
	}

	log.Printf("[github] Removed repo config id=%d", id)
	respond.Success(w, nil)
}

// --- Webhook handler ---

func HandleGitHub(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		respond.Error(w, "Method not allowed")
		return
	}

	apiKey := r.URL.Query().Get("api_key")
	repoIDStr := r.URL.Query().Get("repo_id")
	repoID, _ := strconv.Atoi(repoIDStr)

	if apiKey == "" || repoID == 0 {
		respond.Error(w, "Missing required params: api_key, repo_id")
		return
	}

	if !authenticateWebhook(apiKey) {
		respond.Error(w, "Invalid API key")
		return
	}

	repo, err := lookupRepo(repoID)
	if err != nil {
		respond.Error(w, "Unknown repo_id")
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
		respond.Success(w, nil)
		return
	}

	// If the repo has a default topic, use that instead.
	if repo.DefaultTopic != "" {
		topic = repo.DefaultTopic
	}

	plainText := stripHTMLForMarkdown(htmlContent)

	senderID := WebhookUserID
	if senderID == 0 {
		senderID = 1
	}

	msgID, err := messages.SendMessageHTML(senderID, repo.ChannelID, topic, plainText, htmlContent)
	if err != nil {
		log.Printf("[webhook] Failed to send message: %v", err)
		respond.Error(w, "Failed to send message")
		return
	}

	messages.MarkUnreadForSubscribers(msgID, repo.ChannelID, senderID)

	// Look up sender info for the event.
	var senderEmail, senderName string
	DB.QueryRow(`SELECT email, full_name FROM users WHERE id = ?`, senderID).Scan(&senderEmail, &senderName)

	channelID := repo.ChannelID
	timestamp := time.Now().Unix()
	events.PushFiltered(map[string]interface{}{
		"type":  "message",
		"flags": []string{},
		"message": map[string]interface{}{
			"id":                msgID,
			"content":           htmlContent,
			"sender_id":         senderID,
			"sender_email":      senderEmail,
			"sender_full_name":  senderName,
			"stream_id":         channelID,
			"subject":           topic,
			"timestamp":         timestamp,
			"type":              "stream",
			"flags":             []string{},
			"reactions":         []interface{}{},
			"display_recipient": fmt.Sprintf("channel_%d", channelID),
		},
	}, func(userID int) bool {
		return channels.CanAccess(userID, channelID)
	})

	log.Printf("[webhook] GitHub %s → %s/%s channel %d, topic %q",
		eventType, repo.Owner, repo.Name, repo.ChannelID, topic)
	respond.Success(w, map[string]interface{}{"id": msgID})
}

func authenticateWebhook(apiKey string) bool {
	var count int
	DB.QueryRow(
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

	if action == "closed" && merged {
		action = "merged"
	}

	switch action {
	case "opened", "closed", "merged", "reopened":
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

func stripHTMLForMarkdown(s string) string {
	s = strings.ReplaceAll(s, "<ul>", "\n")
	s = strings.ReplaceAll(s, "</ul>", "")
	s = strings.ReplaceAll(s, "<li>", "- ")
	s = strings.ReplaceAll(s, "</li>", "\n")
	s = strings.ReplaceAll(s, "<b>", "**")
	s = strings.ReplaceAll(s, "</b>", "**")
	s = strings.ReplaceAll(s, "<code>", "`")
	s = strings.ReplaceAll(s, "</code>", "`")
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
