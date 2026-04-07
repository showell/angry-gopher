// Tests for message flags: read/unread and starred.
//
// Internally, "read" is the default (no row in the unreads table),
// and "unread" is stored explicitly. The flags package translates
// between the Zulip API convention and our internal representation.

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"angry-gopher/flags"
)

func TestMessagesDefaultToRead(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	f := flagsFor(t, getMessages(t, "newest")[0])
	if !hasFlag(f, "read") {
		t.Errorf("expected 'read' flag, got %v", f)
	}
}

func TestMarkUnreadThenRead(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "remove", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(f, "read") {
			t.Errorf("should be unread, got %v", f)
		}
	}

	postFlags(t, "add", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "read") {
			t.Errorf("should be read again, got %v", f)
		}
	}
}

func TestStarredFlag(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "add", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "starred") {
			t.Errorf("should be starred, got %v", f)
		}
		if !hasFlag(f, "read") {
			t.Errorf("starring should not remove read, got %v", f)
		}
	}

	postFlags(t, "remove", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(f, "starred") {
			t.Errorf("should no longer be starred, got %v", f)
		}
	}
}

func TestBatchFlagUpdate(t *testing.T) {
	resetDB()
	seedMessage(t, 1)
	seedMessage(t, 2)
	seedMessage(t, 3)

	// Mark 1 and 3 as unread; 2 stays read.
	postFlags(t, "remove", "read", "[1,3]")

	for _, msg := range getMessages(t, "newest") {
		id := int(msg["id"].(float64))
		f := flagsFor(t, msg)
		switch id {
		case 1, 3:
			if hasFlag(f, "read") {
				t.Errorf("message %d should be unread, got %v", id, f)
			}
		case 2:
			if !hasFlag(f, "read") {
				t.Errorf("message %d should still be read, got %v", id, f)
			}
		}
	}
}

func TestSendMessageDefaultsToRead(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "content")

	f := flagsFor(t, getMessages(t, "newest")[0])
	if !hasFlag(f, "read") {
		t.Errorf("sent messages should default to read, got %v", f)
	}
}

func TestFlagUpdateResponse(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := postFlags(t, "add", "starred", "[1]")
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Errorf("expected result=success, got %v", body["result"])
	}
}

func TestFlagUpdateMissingParams(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("POST", "/api/v1/messages/flags", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	flags.HandleUpdateFlags(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing params, got %v", body["result"])
	}
}

func TestFlagUpdateInvalidOp(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := postFlags(t, "toggle", "read", "[1]")
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for invalid op, got %v", body["result"])
	}
}

func TestIdempotentFlagOperations(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	// Adding read twice (already read by default) should not error.
	postFlags(t, "add", "read", "[1]")
	postFlags(t, "add", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "read") {
			t.Errorf("should still be read after double add, got %v", f)
		}
	}

	// Starring twice should not error (INSERT OR IGNORE in SQLite
	// silently skips if the row already exists).
	postFlags(t, "add", "starred", "[1]")
	postFlags(t, "add", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "starred") {
			t.Errorf("should still be starred after double add, got %v", f)
		}
	}
}
