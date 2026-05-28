// Docs storage: a per-user collection of markdown files, one file per doc,
// in `<ChatDataRoot>/users/<uid>/docs/<slug>.md`. The on-disk shape is the
// whole model — filename IS the title (slugified), body IS the file. No
// metadata, no index, no rename: `ls` the dir and you have the doc list.
// Each user only sees their own dir; there's no sharing or cross-user
// addressing in v1.
//
// Why under chat's data root: docs are a small authoring surface that
// rides on the chat subsystem (sub-nav slot, member-only auth, shared
// markdown renderer). Putting the files under ChatDataRoot keeps backup
// and migration aligned with chat and avoids a second data-root knob.
// Namespaced under `users/` so it can't collide with conversation
// pair-key dirs (which are `<a>_<b>` directly under ChatDataRoot).
package chat

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// userDocsDir is one user's private docs directory.
func userDocsDir(uid string) string {
	return filepath.Join(ChatDataRoot, "users", uid, "docs")
}

// docPath resolves a (user, slug) pair to its on-disk file. The slug is
// re-validated here so this is also the chokepoint that protects against
// path-traversal — a caller who threads an attacker-controlled string
// through gets a clean error, not a write outside the user's dir.
func docPath(uid, slug string) (string, error) {
	if !validDocSlug(slug) {
		return "", fmt.Errorf("invalid doc slug")
	}
	return filepath.Join(userDocsDir(uid), slug+".md"), nil
}

// docSlugRe is the canonical slug shape: lowercase letters, digits, and
// hyphens, no leading/trailing hyphen, 1..80 chars. Anything else can't
// come from slugifyTitle and won't be accepted from a URL either.
var docSlugRe = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)

func validDocSlug(slug string) bool {
	return len(slug) >= 1 && len(slug) <= 80 && docSlugRe.MatchString(slug)
}

// reservedDocSlugs would collide with the literal /chat/docs/<verb> routes
// (list, new, save, render, post): /chat/docs/<name> must route to the verb,
// not a doc. Creation steps over these names; they're still valid as URL
// input (no such file exists, so a read just 404s).
var reservedDocSlugs = map[string]bool{
	"list": true, "new": true, "save": true, "render": true, "post": true,
}

// slugifyTitle reduces a free-form title to a filename slug: lowercase,
// non-alphanumerics collapsed to single hyphens, trimmed. Returns
// "untitled" if the title is empty or all-symbol.
func slugifyTitle(title string) string {
	var b strings.Builder
	prevHyphen := false
	for _, r := range strings.ToLower(strings.TrimSpace(title)) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevHyphen = false
		default:
			if !prevHyphen && b.Len() > 0 {
				b.WriteByte('-')
				prevHyphen = true
			}
		}
	}
	out := strings.TrimRight(b.String(), "-")
	if out == "" {
		out = "untitled"
	}
	if len(out) > 80 {
		out = strings.TrimRight(out[:80], "-")
	}
	return out
}

// uniqueDocSlug returns a slug guaranteed not to collide with an existing
// file in the user's dir, appending "-2", "-3", … as needed. Caller still
// races (no lock around create), but a collision there just means the
// second writer overwrites — acceptable for the single-author surface.
func uniqueDocSlug(uid, base string) string {
	if !reservedDocSlugs[base] && !fileExists(filepath.Join(userDocsDir(uid), base+".md")) {
		return base
	}
	for n := 2; n < 1000; n++ {
		cand := fmt.Sprintf("%s-%d", base, n)
		if !fileExists(filepath.Join(userDocsDir(uid), cand+".md")) {
			return cand // suffixed candidates can't hit a reserved name
		}
	}
	return base // give up; caller will just overwrite
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// DocSummary is one entry in the sidebar list.
type DocSummary struct {
	Slug  string
	Title string // currently the slug rendered as a title (hyphens → spaces)
}

// ListUserDocs enumerates a user's docs, alphabetically by slug. A missing
// dir means "no docs yet," not an error.
func ListUserDocs(uid string) ([]DocSummary, error) {
	dir := userDocsDir(uid)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]DocSummary, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		slug := strings.TrimSuffix(name, ".md")
		if !validDocSlug(slug) {
			continue
		}
		out = append(out, DocSummary{Slug: slug, Title: titleFromSlug(slug)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Slug < out[j].Slug })
	return out, nil
}

// titleFromSlug renders a slug back to a display title: hyphens to spaces,
// first letter capitalized. It's a presentational reverse of slugifyTitle,
// not lossless — the filename remains the source of truth.
func titleFromSlug(slug string) string {
	t := strings.ReplaceAll(slug, "-", " ")
	if t == "" {
		return t
	}
	return strings.ToUpper(t[:1]) + t[1:]
}

// ReadUserDoc returns a doc's raw markdown body. A missing file gives
// (empty, nil) — the caller distinguishes "doc not found" via the route.
func ReadUserDoc(uid, slug string) (string, error) {
	path, err := docPath(uid, slug)
	if err != nil {
		return "", err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return string(b), nil
}

// WriteUserDoc overwrites a doc's body. Refuses to create a doc that
// doesn't already exist (use CreateUserDoc for that) — autosave should
// never spawn a brand-new file from a stale slug.
func WriteUserDoc(uid, slug, body string) error {
	path, err := docPath(uid, slug)
	if err != nil {
		return err
	}
	if !fileExists(path) {
		return fmt.Errorf("doc %q does not exist", slug)
	}
	return os.WriteFile(path, []byte(body), 0o644)
}

// CreateUserDoc creates a new empty doc with a title-derived, collision-
// suffixed slug. Returns the chosen slug so the caller can redirect to it.
func CreateUserDoc(uid, title string) (string, error) {
	if err := os.MkdirAll(userDocsDir(uid), 0o755); err != nil {
		return "", err
	}
	slug := uniqueDocSlug(uid, slugifyTitle(title))
	path, err := docPath(uid, slug)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(""), 0o644); err != nil {
		return "", err
	}
	return slug, nil
}
