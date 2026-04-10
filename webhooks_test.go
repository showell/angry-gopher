package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/webhooks"
)

// seedGitHubRepo creates a github_repos row and returns the repo ID.
func seedGitHubRepo(t *testing.T, owner, name string, channelID int, defaultTopic string) int {
	t.Helper()
	form := url.Values{}
	form.Set("owner", owner)
	form.Set("name", name)
	form.Set("channel_id", fmt.Sprintf("%d", channelID))
	form.Set("default_topic", defaultTopic)

	req := httptest.NewRequest("POST", "/gopher/github/repos", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	webhooks.HandleRepos(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("failed to create repo: %v", body)
	}
	return int(body["id"].(float64))
}

func postGitHubWebhook(t *testing.T, eventType string, payload map[string]interface{}, apiKey string, repoID int) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(payload)
	u := fmt.Sprintf("/gopher/webhooks/github?api_key=%s&repo_id=%d", apiKey, repoID)
	req := httptest.NewRequest("POST", u, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", eventType)
	rec := httptest.NewRecorder()
	webhooks.HandleGitHub(rec, req)
	return rec
}

func TestGitHubWebhookPush(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1
	repoID := seedGitHubRepo(t, "showell", "angry-gopher", 3, "")

	payload := map[string]interface{}{
		"ref":     "refs/heads/main",
		"compare": "https://github.com/showell/angry-gopher/compare/abc...def",
		"pusher":  map[string]interface{}{"name": "steve"},
		"repository": map[string]interface{}{
			"full_name": "showell/angry-gopher",
		},
		"commits": []interface{}{
			map[string]interface{}{
				"id":      "abc1234567890",
				"message": "Fix widget rendering in dark mode",
				"url":     "https://github.com/showell/angry-gopher/commit/abc1234",
			},
		},
	}

	rec := postGitHubWebhook(t, "push", payload, "steve-api-key", repoID)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	if body["id"] == nil {
		t.Fatal("expected message id in response")
	}
}

func TestGitHubWebhookPullRequest(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1
	repoID := seedGitHubRepo(t, "showell", "angry-gopher", 3, "")

	payload := map[string]interface{}{
		"action": "opened",
		"pull_request": map[string]interface{}{
			"number":   float64(42),
			"title":    "Add feature X",
			"html_url": "https://github.com/showell/angry-gopher/pull/42",
			"user":     map[string]interface{}{"login": "steve"},
			"merged":   false,
		},
		"repository": map[string]interface{}{
			"full_name": "showell/angry-gopher",
		},
	}

	rec := postGitHubWebhook(t, "pull_request", payload, "steve-api-key", repoID)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
}

func TestGitHubWebhookDefaultTopic(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1
	repoID := seedGitHubRepo(t, "zulip", "zulip", 3, "upstream")

	payload := map[string]interface{}{
		"ref":     "refs/heads/main",
		"pusher":  map[string]interface{}{"name": "tim"},
		"compare": "https://github.com/zulip/zulip/compare/abc...def",
		"repository": map[string]interface{}{
			"full_name": "zulip/zulip",
		},
		"commits": []interface{}{
			map[string]interface{}{
				"id":      "abc1234567890",
				"message": "Fix something",
				"url":     "https://github.com/zulip/zulip/commit/abc1234",
			},
		},
	}

	rec := postGitHubWebhook(t, "push", payload, "steve-api-key", repoID)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	// The message should land in the "upstream" topic, not the auto-generated one.
	// We verify by checking the topic in the DB.
	msgID := int(body["id"].(float64))
	var topicName string
	DB.QueryRow(`SELECT t.topic_name FROM messages m JOIN topics t ON m.topic_id = t.topic_id WHERE m.id = ?`, msgID).Scan(&topicName)
	if topicName != "upstream" {
		t.Fatalf("expected topic 'upstream', got %q", topicName)
	}
}

func TestGitHubWebhookIgnoresUnknownEvent(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1
	repoID := seedGitHubRepo(t, "showell", "angry-gopher", 3, "")

	payload := map[string]interface{}{
		"action":     "completed",
		"repository": map[string]interface{}{"full_name": "showell/angry-gopher"},
	}

	rec := postGitHubWebhook(t, "check_suite", payload, "steve-api-key", repoID)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success for ignored event, got %v", body)
	}
	if body["id"] != nil {
		t.Fatal("expected no message id for ignored event")
	}
}

func TestGitHubWebhookBadAPIKey(t *testing.T) {
	resetDB()
	repoID := seedGitHubRepo(t, "showell", "angry-gopher", 3, "")

	payload := map[string]interface{}{
		"repository": map[string]interface{}{"full_name": "showell/angry-gopher"},
	}

	rec := postGitHubWebhook(t, "push", payload, "wrong-key", repoID)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error for bad API key, got %v", body)
	}
}

func TestGitHubWebhookBadRepoID(t *testing.T) {
	resetDB()

	payload := map[string]interface{}{
		"repository": map[string]interface{}{"full_name": "showell/angry-gopher"},
	}

	rec := postGitHubWebhook(t, "push", payload, "steve-api-key", 999)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error for bad repo_id, got %v", body)
	}
}

func TestGitHubReposCRUD(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1

	// Create a repo.
	repoID := seedGitHubRepo(t, "showell", "angry-cat", 3, "cat-dev")

	// List repos.
	req := httptest.NewRequest("GET", "/gopher/github/repos", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	webhooks.HandleRepos(rec, req)
	body := parseJSON(t, rec)
	repos := body["repos"].([]interface{})
	if len(repos) != 1 {
		t.Fatalf("expected 1 repo, got %d", len(repos))
	}
	repo := repos[0].(map[string]interface{})
	if repo["owner"] != "showell" || repo["name"] != "angry-cat" {
		t.Fatalf("unexpected repo: %v", repo)
	}

	// Delete it.
	form := url.Values{}
	form.Set("id", fmt.Sprintf("%d", repoID))
	req = httptest.NewRequest("DELETE", "/gopher/github/repos", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec = httptest.NewRecorder()
	webhooks.HandleRepos(rec, req)
	body = parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success on delete, got %v", body)
	}

	// List again — should be empty.
	req = httptest.NewRequest("GET", "/gopher/github/repos", nil)
	steveAuth(req)
	rec = httptest.NewRecorder()
	webhooks.HandleRepos(rec, req)
	body = parseJSON(t, rec)
	if body["repos"] != nil {
		repos = body["repos"].([]interface{})
		if len(repos) != 0 {
			t.Fatalf("expected 0 repos after delete, got %d", len(repos))
		}
	}
}
