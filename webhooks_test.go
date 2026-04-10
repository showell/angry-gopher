package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"angry-gopher/webhooks"
)

func postGitHubWebhook(t *testing.T, eventType string, payload map[string]interface{}, apiKey string, channelID int) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(payload)
	url := "/gopher/webhooks/github?api_key=" + apiKey + "&channel_id=" + string(rune('0'+channelID))
	if channelID >= 10 {
		url = "/gopher/webhooks/github?api_key=" + apiKey + "&channel_id=10"
	}
	req := httptest.NewRequest("POST", url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", eventType)
	rec := httptest.NewRecorder()
	webhooks.HandleGitHub(rec, req)
	return rec
}

func TestGitHubWebhookPush(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1

	payload := map[string]interface{}{
		"ref":     "refs/heads/main",
		"compare": "https://github.com/org/repo/compare/abc...def",
		"pusher":  map[string]interface{}{"name": "steve"},
		"repository": map[string]interface{}{
			"full_name": "org/repo",
		},
		"commits": []interface{}{
			map[string]interface{}{
				"id":      "abc1234567890",
				"message": "Fix the widget",
				"url":     "https://github.com/org/repo/commit/abc1234",
			},
		},
	}

	rec := postGitHubWebhook(t, "push", payload, "steve-api-key", 3)
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

	payload := map[string]interface{}{
		"action": "opened",
		"pull_request": map[string]interface{}{
			"number":   float64(42),
			"title":    "Add feature X",
			"html_url": "https://github.com/org/repo/pull/42",
			"user":     map[string]interface{}{"login": "steve"},
			"merged":   false,
		},
		"repository": map[string]interface{}{
			"full_name": "org/repo",
		},
	}

	rec := postGitHubWebhook(t, "pull_request", payload, "steve-api-key", 3)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
}

func TestGitHubWebhookPRMerged(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1

	payload := map[string]interface{}{
		"action": "closed",
		"pull_request": map[string]interface{}{
			"number":   float64(42),
			"title":    "Add feature X",
			"html_url": "https://github.com/org/repo/pull/42",
			"user":     map[string]interface{}{"login": "steve"},
			"merged":   true,
		},
		"repository": map[string]interface{}{
			"full_name": "org/repo",
		},
	}

	rec := postGitHubWebhook(t, "pull_request", payload, "steve-api-key", 3)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
}

func TestGitHubWebhookIssue(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1

	payload := map[string]interface{}{
		"action": "opened",
		"issue": map[string]interface{}{
			"number":   float64(7),
			"title":    "Bug in login",
			"html_url": "https://github.com/org/repo/issues/7",
			"user":     map[string]interface{}{"login": "apoorva"},
		},
		"repository": map[string]interface{}{
			"full_name": "org/repo",
		},
	}

	rec := postGitHubWebhook(t, "issues", payload, "steve-api-key", 3)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
}

func TestGitHubWebhookIgnoresUnknownEvent(t *testing.T) {
	resetDB()
	webhooks.WebhookUserID = 1

	payload := map[string]interface{}{
		"action":     "completed",
		"repository": map[string]interface{}{"full_name": "org/repo"},
	}

	rec := postGitHubWebhook(t, "check_suite", payload, "steve-api-key", 3)
	body := parseJSON(t, rec)
	// Should succeed silently — acknowledged but not posted.
	if body["result"] != "success" {
		t.Fatalf("expected success for ignored event, got %v", body)
	}
	if body["id"] != nil {
		t.Fatal("expected no message id for ignored event")
	}
}

func TestGitHubWebhookBadAPIKey(t *testing.T) {
	resetDB()

	payload := map[string]interface{}{
		"repository": map[string]interface{}{"full_name": "org/repo"},
	}

	rec := postGitHubWebhook(t, "push", payload, "wrong-key", 3)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error for bad API key, got %v", body)
	}
}

func TestGitHubWebhookBadChannel(t *testing.T) {
	resetDB()

	payload := map[string]interface{}{
		"repository": map[string]interface{}{"full_name": "org/repo"},
	}

	rec := postGitHubWebhook(t, "push", payload, "steve-api-key", 9)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error for bad channel, got %v", body)
	}
}
