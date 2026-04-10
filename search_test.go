package main

import (
	"fmt"
	"net/http/httptest"
	"testing"

	"angry-gopher/search"
)

func searchGet(t *testing.T, queryString string) map[string]interface{} {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/search?"+queryString, nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	search.HandleSearch(rec, req)
	return parseJSON(t, rec)
}

func searchMessages(t *testing.T, queryString string) []interface{} {
	t.Helper()
	body := searchGet(t, queryString)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	msgs, _ := body["messages"].([]interface{})
	return msgs
}

func TestSearchByChannel(t *testing.T) {
	resetDB()
	sendMessage(t, 3, "hello", "msg1") // channel 3 (ChitChat, public)
	sendMessage(t, 3, "hello", "msg2")
	sendMessage(t, 1, "other", "msg3") // channel 1 (private)

	msgs := searchMessages(t, "channel_id=3")
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages in channel 3, got %d", len(msgs))
	}

	// Verify ID tuples — no content field.
	msg := msgs[0].(map[string]interface{})
	if msg["content_id"] == nil {
		t.Fatal("expected content_id in result")
	}
	if msg["content"] != nil {
		t.Fatal("search should not return content")
	}
}

func TestSearchByChannelAndTopic(t *testing.T) {
	resetDB()
	sendMessage(t, 3, "alpha", "msg1")
	sendMessage(t, 3, "alpha", "msg2")
	sendMessage(t, 3, "beta", "msg3")

	// We need to look up topic_id for "alpha" in channel 3.
	var topicID int
	DB.QueryRow(`SELECT topic_id FROM topics WHERE channel_id = 3 AND topic_name = 'alpha'`).Scan(&topicID)

	msgs := searchMessages(t, "channel_id=3&topic_id="+itoa(topicID))
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages in alpha, got %d", len(msgs))
	}
}

func TestSearchBySender(t *testing.T) {
	resetDB()
	sendMessage(t, 3, "hello", "from steve") // Steve is user 1

	msgs := searchMessages(t, "sender_id=1")
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message from Steve, got %d", len(msgs))
	}

	msgs = searchMessages(t, "sender_id=4") // Joe sent nothing
	if len(msgs) != 0 {
		t.Fatalf("expected 0 messages from Joe, got %d", len(msgs))
	}
}

func TestSearchMultipleSenders(t *testing.T) {
	resetDB()
	sendMessage(t, 3, "hello", "from steve")

	// Steve is user 1 — search for users 1 and 4 (buddy list).
	msgs := searchMessages(t, "sender_ids=1,4")
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message from buddy list, got %d", len(msgs))
	}
}

func TestSearchPagination(t *testing.T) {
	resetDB()
	for i := 0; i < 5; i++ {
		sendMessage(t, 3, "page", "msg")
	}

	msgs := searchMessages(t, "channel_id=3&limit=3")
	if len(msgs) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(msgs))
	}

	// Get the lowest ID from this page.
	lastMsg := msgs[len(msgs)-1].(map[string]interface{})
	lastID := int(lastMsg["id"].(float64))

	// Next page.
	msgs = searchMessages(t, "channel_id=3&limit=3&before="+itoa(lastID))
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages on page 2, got %d", len(msgs))
	}
}

func TestSearchReturnsNewestFirst(t *testing.T) {
	resetDB()
	sendMessage(t, 3, "order", "first")
	sendMessage(t, 3, "order", "second")

	msgs := searchMessages(t, "channel_id=3")
	first := msgs[0].(map[string]interface{})
	second := msgs[1].(map[string]interface{})

	if first["id"].(float64) <= second["id"].(float64) {
		t.Fatal("expected newest first")
	}
}

func TestSearchAccessControl(t *testing.T) {
	resetDB()
	// Send to private channel 1 (Steve, Apoorva, Claude are subscribed; Joe is not).
	sendMessage(t, 1, "secret", "private msg")

	// Steve can see it.
	msgs := searchMessages(t, "channel_id=1")
	if len(msgs) != 1 {
		t.Fatalf("Steve should see private channel, got %d", len(msgs))
	}

	// Joe cannot.
	req := httptest.NewRequest("GET", "/api/v1/search?channel_id=1", nil)
	joeAuth(req)
	rec := httptest.NewRecorder()
	search.HandleSearch(rec, req)
	body := parseJSON(t, rec)
	joeMsgs, _ := body["messages"].([]interface{})
	if len(joeMsgs) != 0 {
		t.Fatalf("Joe should not see private channel, got %d", len(joeMsgs))
	}
}

func TestSearchRequiresAuth(t *testing.T) {
	resetDB()
	req := httptest.NewRequest("GET", "/api/v1/search", nil)
	rec := httptest.NewRecorder()
	search.HandleSearch(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error without auth, got %v", body)
	}
}

func itoa(n int) string {
	return fmt.Sprintf("%d", n)
}
