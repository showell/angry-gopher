// Tests for emoji reactions: add, remove, multiple, and idempotency.

package main

import "testing"

func TestAddReaction(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := postReaction(t, "POST", 1, "thumbs_up", "1f44d")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	// Verify the reaction appears in the messages response.
	rxns := getMessages(t, "newest")[0]["reactions"].([]interface{})
	if len(rxns) != 1 {
		t.Fatalf("expected 1 reaction, got %d", len(rxns))
	}
	rxn := rxns[0].(map[string]interface{})
	if rxn["emoji_name"] != "thumbs_up" {
		t.Errorf("expected thumbs_up, got %v", rxn["emoji_name"])
	}
	if rxn["emoji_code"] != "1f44d" {
		t.Errorf("expected 1f44d, got %v", rxn["emoji_code"])
	}
}

func TestRemoveReaction(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postReaction(t, "POST", 1, "thumbs_up", "1f44d")
	postReaction(t, "DELETE", 1, "thumbs_up", "1f44d")

	rxns := getMessages(t, "newest")[0]["reactions"].([]interface{})
	if len(rxns) != 0 {
		t.Errorf("expected 0 reactions after removal, got %d", len(rxns))
	}
}

func TestMultipleReactions(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postReaction(t, "POST", 1, "thumbs_up", "1f44d")
	postReaction(t, "POST", 1, "heart", "2764")

	rxns := getMessages(t, "newest")[0]["reactions"].([]interface{})
	if len(rxns) != 2 {
		t.Errorf("expected 2 reactions, got %d", len(rxns))
	}
}

func TestIdempotentReaction(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	// Adding the same reaction twice should not error or duplicate
	// (INSERT OR IGNORE in SQLite).
	postReaction(t, "POST", 1, "thumbs_up", "1f44d")
	postReaction(t, "POST", 1, "thumbs_up", "1f44d")

	rxns := getMessages(t, "newest")[0]["reactions"].([]interface{})
	if len(rxns) != 1 {
		t.Errorf("expected 1 reaction after double add, got %d", len(rxns))
	}
}
