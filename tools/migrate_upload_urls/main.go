// migrate_upload_urls rewrites stranded chat image URLs from the dead
// pre-path-style form to the current serving form:
//
//	old: /chat/uploads/<conv>/<sid>/<file>
//	new: /chat/c/<conv>/<sid>/uploads/<file>
//
// Why: when chat went session-aware + path-style (2026-05-28) the image
// serving route moved to /chat/c/<conv>/<sid>/uploads/<file>, but two
// sources left the old /chat/uploads/... prefix baked into stored message
// bodies: (1) messages posted in the brief window before that deploy
// landed, and (2) archive_chat_session, which inserted the session-id
// segment but kept the /chat/uploads/ prefix. The old form has no route,
// so those images 404 in the live UI. The bytes are fine on disk — only
// the URL string in the body is stale — so this is a pure text rewrite;
// no files move.
//
// One-shot, idempotent: a body already in the new form won't match, so
// it's safe to re-run. Run while the server is stopped (or the
// conversation otherwise quiet): we don't take the chat mutex, and a
// concurrent append could race the read-modify-write of a session file.
//
// Usage:
//
//	go run ./tools/migrate_upload_urls/ <chat-data-root>
//
// Walks <chat-data-root>/<conv>/sessions/*.md and rewrites each in place.
// For every rewrite it checks the backing file exists at
// <conv>/sessions/<sid>.uploads/<file> and warns if not (the URL is still
// rewritten — the old form 404s regardless).
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// oldUploadRe matches the dead 3-segment form. The file segment is the
// upload token shape (32 hex + an allowed image ext), so the boundary
// after the session-id segment is unambiguous. conv is "<a>_<b>"; the
// session id is a date-prefixed slug (no underscores, no slashes).
var oldUploadRe = regexp.MustCompile(`/chat/uploads/([0-9]+_[0-9]+)/([A-Za-z0-9-]+)/([a-f0-9]{32}\.(?:png|jpg|gif|webp))`)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: migrate_upload_urls <chat-data-root>")
		os.Exit(1)
	}
	root := os.Args[1]
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "not a directory: %s\n", root)
		os.Exit(1)
	}

	convs, err := os.ReadDir(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read root: %v\n", err)
		os.Exit(1)
	}

	totalFiles, totalRewrites, totalMissing := 0, 0, 0
	for _, c := range convs {
		// Conv dirs are "<a>_<b>"; skip the users/ state subtree and any
		// other non-conversation entries.
		if !c.IsDir() || c.Name() == "users" {
			continue
		}
		sessionsDir := filepath.Join(root, c.Name(), "sessions")
		entries, err := os.ReadDir(sessionsDir)
		if err != nil {
			continue // no sessions dir => not a conversation we migrate
		}
		for _, e := range entries {
			if e.IsDir() || filepath.Ext(e.Name()) != ".md" {
				continue // skip <sid>.uploads/ dirs and non-transcripts
			}
			path := filepath.Join(sessionsDir, e.Name())
			rewrites, missing := migrateFile(path, root)
			if rewrites > 0 {
				totalFiles++
				totalRewrites += rewrites
				totalMissing += missing
				fmt.Printf("  %s: rewrote %d URL(s)%s\n", path, rewrites,
					missingNote(missing))
			}
		}
	}
	fmt.Printf("done: %d file(s), %d URL(s) rewritten, %d backing file(s) missing\n",
		totalFiles, totalRewrites, totalMissing)
}

func missingNote(missing int) string {
	if missing == 0 {
		return ""
	}
	return fmt.Sprintf(" (%d with NO backing file — check these)", missing)
}

// migrateFile rewrites one session file in place. Returns (rewrites,
// missingBackingFiles). A missing backing file is warned but still
// rewritten: the old form 404s either way, and the new form at least
// points where the file should be.
func migrateFile(path, root string) (int, int) {
	src, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "    read %s: %v\n", path, err)
		return 0, 0
	}
	rewrites, missing := 0, 0
	out := oldUploadRe.ReplaceAllFunc(src, func(match []byte) []byte {
		m := oldUploadRe.FindSubmatch(match)
		conv, sid, file := string(m[1]), string(m[2]), string(m[3])
		backing := filepath.Join(root, conv, "sessions", sid+".uploads", file)
		if _, err := os.Stat(backing); err != nil {
			missing++
			fmt.Fprintf(os.Stderr, "    %s: backing file missing: %s\n", path, backing)
		}
		rewrites++
		return []byte("/chat/c/" + conv + "/" + sid + "/uploads/" + file)
	})
	if rewrites == 0 {
		return 0, 0 // nothing matched; leave the file (and its mtime) alone
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "    write %s: %v\n", path, err)
		return 0, missing
	}
	return rewrites, missing
}
