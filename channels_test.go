// Tests for channel-related endpoints: subscriptions, channel creation,
// and channel updates.

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

	// Verify both raw markdown and rendered HTML are stored
	// in the channel_descriptions table (not the old inline
	// columns on channels).
	var markdown, html string
	DB.QueryRow(`SELECT markdown, html FROM channel_descriptions WHERE channel_id = 1`).
		Scan(&markdown, &html)

	if markdown != "A channel for **testing**" {
		t.Errorf("expected raw markdown stored, got %q", markdown)
	}
	if !strings.Contains(html, "<strong>testing</strong>") {
		t.Errorf("expected rendered HTML, got %q", html)
	}
}

func TestCreatePublicChannel(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("subscriptions", `[{"name":"new-channel","description":"A new channel"}]`)
	form.Set("principals", "[1,2]")

	req := httptest.NewRequest("POST", "/api/v1/users/me/subscriptions", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleCreateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	// Channel should exist.
	var channelID int
	DB.QueryRow(`SELECT channel_id FROM channels WHERE name = 'new-channel'`).Scan(&channelID)
	if channelID == 0 {
		t.Fatal("channel was not created")
	}

	// Both Steve (1) and Apoorva (2) should be subscribed.
	var subCount int
	DB.QueryRow(`SELECT COUNT(*) FROM subscriptions WHERE channel_id = ?`, channelID).Scan(&subCount)
	if subCount != 2 {
		t.Errorf("expected 2 subscribers, got %d", subCount)
	}
}

func TestCreatePrivateChannel(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("subscriptions", `[{"name":"secret-channel","description":""}]`)
	form.Set("invite_only", "true")
	form.Set("principals", "[1,3]")

	req := httptest.NewRequest("POST", "/api/v1/users/me/subscriptions", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleCreateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	var inviteOnly int
	DB.QueryRow(`SELECT invite_only FROM channels WHERE name = 'secret-channel'`).Scan(&inviteOnly)
	if inviteOnly != 1 {
		t.Errorf("expected invite_only=1, got %d", inviteOnly)
	}
}

func TestCreateDuplicateChannelIgnored(t *testing.T) {
	resetDB()

	// "Angry Cat" already exists in seed data.
	form := url.Values{}
	form.Set("subscriptions", `[{"name":"Angry Cat","description":"duplicate"}]`)
	form.Set("principals", "[1]")

	req := httptest.NewRequest("POST", "/api/v1/users/me/subscriptions", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleCreateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	// Should still be just 3 channels.
	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM channels`).Scan(&count)
	if count != 3 {
		t.Errorf("expected 3 channels (no duplicate), got %d", count)
	}
}
