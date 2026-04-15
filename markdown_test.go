// Tests for Zulip-specific markdown extensions: mentions, channel links,
// topic links, and message links.

package main

import (
	"strings"
	"testing"
)

func TestMentionKnownUser(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "hello @**Steve**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if !strings.Contains(content, `class="user-mention"`) {
		t.Errorf("expected user-mention span, got %q", content)
	}
	if !strings.Contains(content, `data-user-id="1"`) {
		t.Errorf("expected data-user-id for Steve, got %q", content)
	}
	if !strings.Contains(content, `@Steve`) {
		t.Errorf("expected display name in mention, got %q", content)
	}
}

func TestMentionUnknownUser(t *testing.T) {
	resetDB()

	// Unknown name should be rendered as bold by goldmark.
	sendMessage(t, 1, "test", "hello @**Nobody**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if strings.Contains(content, "user-mention") {
		t.Errorf("unknown user should not get mention span, got %q", content)
	}
}

func TestChannelLink(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "check out #**Angry Gopher**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if !strings.Contains(content, `/#narrow/channel/2-`) {
		t.Errorf("expected narrow link with channel ID 2, got %q", content)
	}
	if !strings.Contains(content, `#Angry Gopher</a>`) {
		t.Errorf("expected channel display name, got %q", content)
	}
}

func TestTopicLink(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "see #**Angry Gopher>dev log**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if !strings.Contains(content, `/topic/dev`) {
		t.Errorf("expected topic in URL, got %q", content)
	}
	// The ">" gets HTML-escaped by goldmark.
	if !strings.Contains(content, `Angry Gopher &gt; dev log</a>`) {
		t.Errorf("expected channel > topic display, got %q", content)
	}
}

func TestMessageLink(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "see #**Angry Gopher>dev log@3**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if !strings.Contains(content, `/near/3`) {
		t.Errorf("expected near/3 in URL, got %q", content)
	}
	if !strings.Contains(content, `@ 3</a>`) {
		t.Errorf("expected message ID in display, got %q", content)
	}
}

func TestUnknownChannelLink(t *testing.T) {
	resetDB()

	// Unknown channel should be left as-is (rendered as bold by goldmark).
	sendMessage(t, 1, "test", "see #**NoSuchChannel**")

	content := getMessages(t, "newest")[0]["content"].(string)
	if strings.Contains(content, "narrow/channel") {
		t.Errorf("unknown channel should not get a link, got %q", content)
	}
}
