package main

import (
	"strings"
	"testing"
)

func TestLinkifierBareIssue(t *testing.T) {
	resetDB()
	// Configure one repo.
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-gopher', 3, '')`)

	html := renderMarkdown("Fixed #42 today")
	if !strings.Contains(html, "github.com/showell/angry-gopher/issues/42") {
		t.Fatalf("expected GitHub link, got: %s", html)
	}
}

func TestLinkifierPrefix(t *testing.T) {
	resetDB()
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-gopher', 3, 'AG')`)
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-cat', 3, 'AC')`)

	html := renderMarkdown("See AG#123 and AC#456")
	if !strings.Contains(html, "angry-gopher/issues/123") {
		t.Fatalf("expected AG link, got: %s", html)
	}
	if !strings.Contains(html, "angry-cat/issues/456") {
		t.Fatalf("expected AC link, got: %s", html)
	}
}

func TestLinkifierExplicitRepo(t *testing.T) {
	resetDB()
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-gopher', 3, '')`)

	html := renderMarkdown("See showell/angry-gopher#99")
	if !strings.Contains(html, "github.com/showell/angry-gopher/issues/99") {
		t.Fatalf("expected explicit repo link, got: %s", html)
	}
}

func TestLinkifierCommitHash(t *testing.T) {
	resetDB()
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-gopher', 3, '')`)

	html := renderMarkdown("Fixed in abc1234def")
	if !strings.Contains(html, "github.com/showell/angry-gopher/commit/abc1234def") {
		t.Fatalf("expected commit link, got: %s", html)
	}
}

func TestLinkifierNoRepos(t *testing.T) {
	resetDB()
	// No repos configured — #123 should pass through as-is.
	html := renderMarkdown("See #123")
	if strings.Contains(html, "github.com") {
		t.Fatalf("should not linkify without repos, got: %s", html)
	}
}

func TestLinkifierMultipleReposNoPrefix(t *testing.T) {
	resetDB()
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-gopher', 3, '')`)
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES ('showell', 'angry-cat', 3, '')`)

	// With multiple repos and no prefix, bare #123 should NOT linkify
	// (ambiguous). But explicit owner/repo#123 should still work.
	html := renderMarkdown("See #123")
	if strings.Contains(html, "github.com") {
		t.Fatalf("bare #123 should be ambiguous with multiple repos, got: %s", html)
	}

	html = renderMarkdown("See showell/angry-gopher#123")
	if !strings.Contains(html, "angry-gopher/issues/123") {
		t.Fatalf("explicit repo should still work, got: %s", html)
	}
}
