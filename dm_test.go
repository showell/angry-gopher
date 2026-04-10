package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/dm"
	"angry-gopher/events"
)

func sendDM(t *testing.T, email, apiKey string, recipientID int, content string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("to", string(rune('0'+recipientID)))
	form.Set("content", content)

	req := httptest.NewRequest("POST", "/api/v1/dm/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	dm.HandleMessages(rec, req)
	return rec
}

func getDMs(t *testing.T, email, apiKey string, otherUserID int) *httptest.ResponseRecorder {
	t.Helper()
	path := "/api/v1/dm/messages?user_id=" + string(rune('0'+otherUserID))
	req := httptest.NewRequest("GET", path, nil)
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	dm.HandleMessages(rec, req)
	return rec
}

func TestDMSendAndRetrieve(t *testing.T) {
	resetDB()

	// Steve (1) sends a DM to Joe (4).
	rec := sendDM(t, "steve@example.com", "steve-api-key", 4, "Hey Joe!")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	if body["id"] == nil {
		t.Fatal("expected message id")
	}

	// Steve retrieves messages with Joe.
	rec = getDMs(t, "steve@example.com", "steve-api-key", 4)
	body = parseJSON(t, rec)
	msgs := body["messages"].([]interface{})
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	// Joe retrieves the same conversation.
	rec = getDMs(t, "joe@example.com", "joe-api-key", 1)
	body = parseJSON(t, rec)
	msgs = body["messages"].([]interface{})
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message from Joe's side, got %d", len(msgs))
	}
}

func TestDMConversationList(t *testing.T) {
	resetDB()

	// Steve sends DMs to two different people.
	sendDM(t, "steve@example.com", "steve-api-key", 2, "Hi Apoorva")
	sendDM(t, "steve@example.com", "steve-api-key", 4, "Hi Joe")

	// Steve should see 2 conversations.
	req := httptest.NewRequest("GET", "/api/v1/dm/conversations", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	dm.HandleConversations(rec, req)
	body := parseJSON(t, rec)
	convos := body["conversations"].([]interface{})
	if len(convos) != 2 {
		t.Fatalf("expected 2 conversations, got %d", len(convos))
	}
}

func TestDMPrivacy(t *testing.T) {
	resetDB()

	// Steve sends a DM to Apoorva.
	sendDM(t, "steve@example.com", "steve-api-key", 2, "Secret message")

	// Joe should not see Steve-Apoorva messages.
	rec := getDMs(t, "joe@example.com", "joe-api-key", 1)
	body := parseJSON(t, rec)
	if body["messages"] != nil {
		msgs := body["messages"].([]interface{})
		if len(msgs) != 0 {
			t.Fatalf("Joe should not see Steve-Apoorva DMs, got %d messages", len(msgs))
		}
	}

	// Joe should see 0 conversations.
	req := httptest.NewRequest("GET", "/api/v1/dm/conversations", nil)
	joeAuth(req)
	rec = httptest.NewRecorder()
	dm.HandleConversations(rec, req)
	body = parseJSON(t, rec)
	if body["conversations"] != nil {
		convos := body["conversations"].([]interface{})
		if len(convos) != 0 {
			t.Fatalf("Joe should see 0 conversations, got %d", len(convos))
		}
	}
}

func TestDMNoEventLeakage(t *testing.T) {
	resetDB()
	events.Reset()

	// Register a queue for Joe.
	joeQueueID := registerQueue(t, joeAuth)

	// Steve sends a DM to Apoorva — Joe should get no events.
	sendDM(t, "steve@example.com", "steve-api-key", 2, "Private to Apoorva")

	stats := events.Stats()
	for _, q := range stats {
		if q.ID == joeQueueID && q.EventCount > 0 {
			t.Fatalf("Joe's queue has %d events from Steve-Apoorva DM — leaking!", q.EventCount)
		}
	}
}

func TestDMEventDelivery(t *testing.T) {
	resetDB()
	events.Reset()

	// Register queues for Steve and Joe.
	steveQueueID := registerQueue(t, steveAuth)
	joeQueueID := registerQueue(t, joeAuth)

	// Steve sends a DM to Joe — both should get the event.
	sendDM(t, "steve@example.com", "steve-api-key", 4, "Hey Joe")

	stats := events.Stats()
	steveEvents, joeEvents := 0, 0
	for _, q := range stats {
		if q.ID == steveQueueID {
			steveEvents = q.EventCount
		}
		if q.ID == joeQueueID {
			joeEvents = q.EventCount
		}
	}
	if steveEvents != 1 {
		t.Fatalf("expected 1 event for Steve, got %d", steveEvents)
	}
	if joeEvents != 1 {
		t.Fatalf("expected 1 event for Joe, got %d", joeEvents)
	}
}

func TestDMCannotSendToSelf(t *testing.T) {
	resetDB()

	rec := sendDM(t, "steve@example.com", "steve-api-key", 1, "Talking to myself")
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error when sending DM to self, got %v", body)
	}
}

func TestDMRequiresAuth(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/api/v1/dm/conversations", nil)
	rec := httptest.NewRecorder()
	dm.HandleConversations(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error without auth, got %v", body)
	}
}
