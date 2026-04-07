// Tests for channel-related endpoints: subscriptions and channel updates.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/channels"
)

func TestSubscriptionsForSteve(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/api/v1/users/me/subscriptions", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleSubscriptions(rec, req)

	body := parseJSON(t, rec)
	subs := body["subscriptions"].([]interface{})

	// Steve is subscribed to all 3 channels.
	if len(subs) != 3 {
		t.Fatalf("expected 3 subscriptions for Steve, got %d", len(subs))
	}
}

func TestUpdateChannelDescription(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("description", "A channel for **testing**")
	req := httptest.NewRequest("PATCH", "/api/v1/streams/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleUpdateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	// Verify both raw markdown and rendered HTML are stored.
	var desc, renderedDesc string
	DB.QueryRow(`SELECT description, rendered_description FROM channels WHERE channel_id = 1`).
		Scan(&desc, &renderedDesc)

	if desc != "A channel for **testing**" {
		t.Errorf("expected raw description stored, got %q", desc)
	}
	if !strings.Contains(renderedDesc, "<strong>testing</strong>") {
		t.Errorf("expected rendered HTML, got %q", renderedDesc)
	}
}
