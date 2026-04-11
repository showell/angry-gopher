package main

import (
	"strings"
	"testing"
)

func addRepo(owner, name, prefix string) {
	DB.Exec(`INSERT INTO github_repos (owner, name, channel_id, prefix) VALUES (?, ?, 3, ?)`,
		owner, name, prefix)
	RefreshLinkifierCache()
}

func TestLinkifierBareIssue(t *testing.T) {
	resetDB()
	addRepo("showell", "angry-gopher", "")

	html := renderMarkdown("Fixed #42 today")
	if !strings.Contains(html, "github.com/showell/angry-gopher/issues/42") {
		t.Fatalf("expected GitHub link, got: %s", html)
	}
}

func TestLinkifierPrefix(t *testing.T) {
	resetDB()
	addRepo("showell", "angry-gopher", "AG")
	addRepo("showell", "angry-cat", "AC")

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
	addRepo("showell", "angry-gopher", "")

	html := renderMarkdown("See showell/angry-gopher#99")
	if !strings.Contains(html, "github.com/showell/angry-gopher/issues/99") {
		t.Fatalf("expected explicit repo link, got: %s", html)
	}
}

func TestLinkifierCommitHash(t *testing.T) {
	resetDB()
	addRepo("showell", "angry-gopher", "")

	html := renderMarkdown("Fixed in abc1234def")
	if !strings.Contains(html, "github.com/showell/angry-gopher/commit/abc1234def") {
		t.Fatalf("expected commit link, got: %s", html)
	}
}

func TestLinkifierNoRepos(t *testing.T) {
	resetDB()
	html := renderMarkdown("See #123")
	if strings.Contains(html, "github.com") {
		t.Fatalf("should not linkify without repos, got: %s", html)
	}
}

func TestLinkifierMultipleReposNoPrefix(t *testing.T) {
	resetDB()
	addRepo("showell", "angry-gopher", "")
	addRepo("showell", "angry-cat", "")

	html := renderMarkdown("See #123")
	if strings.Contains(html, "github.com") {
		t.Fatalf("bare #123 should be ambiguous with multiple repos, got: %s", html)
	}

	html = renderMarkdown("See showell/angry-gopher#123")
	if !strings.Contains(html, "angry-gopher/issues/123") {
		t.Fatalf("explicit repo should still work, got: %s", html)
	}
}
