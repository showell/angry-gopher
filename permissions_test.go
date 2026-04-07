// Permission and access control tests.
//
// SECURITY AUDIT FOCUS: This file contains all tests that verify
// channel visibility rules. Private channels (invite_only=1) should
// only be accessible to subscribers. Public channels are open to all
// authenticated users.
//
// Seeded data reminder:
//   - Channel 1 "Angry Cat"    — private, subscribers: Steve, Apoorva, Claude
//   - Channel 2 "Angry Gopher" — private, subscribers: Steve, Apoorva, Claude
//   - Channel 3 "ChitChat"     — public,  subscribers: Steve, Apoorva, Claude, Joe
//   - Joe Random is the only user without access to private channels.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/channels"
	"angry-gopher/flags"
	"angry-gopher/messages"
	"angry-gopher/reactions"
)

// --- Authentication required ---

func TestSubscriptionsRequiresAuth(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/api/v1/users/me/subscriptions", nil)
	rec := httptest.NewRecorder()
	channels.HandleSubscriptions(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for unauthenticated request, got %v", body["result"])
	}
}

// --- Subscriptions scoped to user ---

func TestSubscriptionsForJoe(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/api/v1/users/me/subscriptions", nil)
	joeAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleSubscriptions(rec, req)

	body := parseJSON(t, rec)
	subs := body["subscriptions"].([]interface{})

	// Joe is only subscribed to ChitChat.
	if len(subs) != 1 {
		t.Fatalf("expected 1 subscription for Joe, got %d", len(subs))
	}
	sub := subs[0].(map[string]interface{})
	if sub["name"] != "ChitChat" {
		t.Errorf("expected ChitChat, got %v", sub["name"])
	}
	if sub["invite_only"] != false {
		t.Errorf("ChitChat should not be invite_only")
	}
}

// --- Message visibility ---

func TestJoeCannotSeePrivateChannelMessages(t *testing.T) {
	resetDB()

	// Steve sends to private channel 1 and public channel 3.
	sendMessage(t, 1, "secret", "private stuff")
	sendMessage(t, 3, "hello", "public stuff")

	// Joe fetches messages — should only see the public one.
	req := httptest.NewRequest("GET", "/api/v1/messages?anchor=newest&num_before=100", nil)
	joeAuth(req)
	rec := httptest.NewRecorder()
	messages.HandleGetMessages(rec, req)

	body := parseJSON(t, rec)
	msgs := body["messages"].([]interface{})
	if len(msgs) != 1 {
		t.Fatalf("Joe should see 1 message (public only), got %d", len(msgs))
	}
	msg := msgs[0].(map[string]interface{})
	if msg["content"] != "<p>public stuff</p>\n" {
		t.Errorf("expected public message, got %q", msg["content"])
	}
}

// --- Sending to channels ---

func TestJoeCannotSendToPrivateChannel(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("to", "1") // Angry Cat (private)
	form.Set("topic", "sneaky")
	form.Set("content", "should not work")
	form.Set("type", "stream")

	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	messages.HandleSendMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("Joe should not be able to send to private channel, got %v", body["result"])
	}
}

func TestJoeCanSendToPublicChannel(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("to", "3") // ChitChat (public)
	form.Set("topic", "hello")
	form.Set("content", "hi everyone")
	form.Set("type", "stream")

	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	messages.HandleSendMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Errorf("Joe should be able to send to public channel, got %v", body["result"])
	}
}

// --- Editing messages in private channels ---

func TestJoeCannotEditPrivateChannelMessage(t *testing.T) {
	resetDB()
	seedMessage(t, 1) // message in channel 1 (Angry Cat, private)

	form := url.Values{}
	form.Set("content", "hacked")
	req := httptest.NewRequest("PATCH", "/api/v1/messages/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	messages.HandleEditMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("Joe should not be able to edit private channel message, got %v", body["result"])
	}
}

// --- Reactions on private channel messages ---

func TestJoeCannotReactToPrivateChannelMessage(t *testing.T) {
	resetDB()
	seedMessage(t, 1) // message in channel 1 (Angry Cat, private)

	form := url.Values{}
	form.Set("emoji_name", "thumbs_up")
	form.Set("emoji_code", "1f44d")
	form.Set("reaction_type", "unicode_emoji")

	req := httptest.NewRequest("POST", "/api/v1/messages/1/reactions", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	reactions.HandleReaction(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("Joe should not be able to react to private channel message, got %v", body["result"])
	}
}

// --- Flags on private channel messages ---

func TestJoeCannotFlagPrivateChannelMessage(t *testing.T) {
	resetDB()
	seedMessage(t, 1) // message in channel 1 (Angry Cat, private)

	form := url.Values{}
	form.Set("op", "add")
	form.Set("flag", "starred")
	form.Set("messages", "[1]")

	req := httptest.NewRequest("POST", "/api/v1/messages/flags", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	flags.HandleUpdateFlags(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("Joe should not be able to flag private channel message, got %v", body["result"])
	}
}

// --- Channel updates on private channels ---

func TestJoeCannotUpdatePrivateChannelDescription(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("description", "hacked description")
	req := httptest.NewRequest("PATCH", "/api/v1/streams/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	channels.HandleUpdateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("Joe should not be able to update private channel description, got %v", body["result"])
	}
}
