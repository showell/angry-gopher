// Tests for message endpoints: send, fetch, edit, and markdown rendering.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/messages"
)

func TestSendMessage(t *testing.T) {
	resetDB()

	rec := sendMessage(t, 1, "greetings", "hello world")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}
	if body["id"] == nil {
		t.Fatal("expected id in response")
	}

	msgs := getMessages(t, "newest")
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	msg := msgs[0]
	if msg["subject"] != "greetings" {
		t.Errorf("expected topic 'greetings', got %v", msg["subject"])
	}
	// Goldmark wraps plain text in <p> tags.
	if msg["content"] != "<p>hello world</p>\n" {
		t.Errorf("expected HTML content, got %q", msg["content"])
	}
}

func TestSendMessageMarkdown(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "code", "here is `inline code` and **bold**")

	content := getMessages(t, "newest")[0]["content"].(string)

	if !strings.Contains(content, "<code>inline code</code>") {
		t.Errorf("expected inline code in HTML, got %q", content)
	}
	if !strings.Contains(content, "<strong>bold</strong>") {
		t.Errorf("expected bold in HTML, got %q", content)
	}
}

func TestSendMessageImagePreview(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "photos", "check this out [photo](/user_uploads/1/cat.png)")

	content := getMessages(t, "newest")[0]["content"].(string)

	// Should contain both the link and an appended inline image preview.
	if !strings.Contains(content, `<a href="/user_uploads/1/cat.png">`) {
		t.Errorf("expected link in HTML, got %q", content)
	}
	if !strings.Contains(content, `<img src="/user_uploads/1/cat.png">`) {
		t.Errorf("expected img preview in HTML, got %q", content)
	}
}

func TestSendMessageNoPreviewForNonImage(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "files", "get the doc [report](/user_uploads/1/report.pdf)")

	content := getMessages(t, "newest")[0]["content"].(string)

	if strings.Contains(content, "<img") {
		t.Errorf("should not have image preview for PDF, got %q", content)
	}
}

func TestSendMessageCreatesNewTopic(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "new topic", "first message")
	sendMessage(t, 1, "new topic", "second message")

	msgs := getMessages(t, "newest")
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}
	if msgs[0]["subject"] != msgs[1]["subject"] {
		t.Errorf("topics should match: %v vs %v", msgs[0]["subject"], msgs[1]["subject"])
	}
}

func TestSendMessageMissingParams(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("to", "1")
	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	messages.HandleSendMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing params, got %v", body["result"])
	}
}

func TestEditMessage(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := editMessage(t, 1, "updated **content**")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	content := getMessages(t, "newest")[0]["content"].(string)
	if !strings.Contains(content, "<strong>content</strong>") {
		t.Errorf("expected rendered markdown, got %q", content)
	}
}

func TestEditMessageMissingContent(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	form := url.Values{}
	req := httptest.NewRequest("PATCH", "/api/v1/messages/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	messages.HandleEditMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing content, got %v", body["result"])
	}
}
