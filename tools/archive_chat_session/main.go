// archive_chat_session migrates one conversation's flat
// messages.md + uploads/ into the new per-session layout: the existing
// transcript becomes sessions/<archive-id>.md (with its uploads sidecar
// renamed accordingly), and an empty sessions/<today>.md is seeded as
// the new current session.
//
// MSG_ ids are renumbered from the old 6-hex hash scheme to the new
// <session-id>_<n> scheme as part of the same pass; references to the
// old ids inside message bodies are rewritten to point at the new ids.
// Image URLs in bodies get their session-id segment inserted too
// (/chat/uploads/<conv>/<file> -> /chat/uploads/<conv>/<archive-id>/<file>).
//
// NOTE (2026-05-28): that rewrite below targets the WRONG form — the live
// serving route is /chat/c/<conv>/<sid>/uploads/<file>, not
// /chat/uploads/<conv>/<sid>/<file>, so the URLs it emits 404. This tool is
// one-shot and already ran; tools/migrate_upload_urls corrects the stranded
// URLs after the fact. If this tool is ever resurrected, fix the target form
// here too (emit /chat/c/<conv>/<archive-id>/uploads/<file>).
//
// One-shot, not idempotent — designed to be run exactly once per conv
// during the introduction of sessions. Refuses to clobber a sessions/
// directory that already exists.
//
// Usage:
//
//	./archive_chat_session <data-root> <conv-key> <archive-id>
//
// Example:
//
//	./archive_chat_session ~/AngryGopher/prod 1_2 2026-05-23
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"angry-gopher/server/chat"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: archive_chat_session <data-root> <conv-key> <archive-id>")
		os.Exit(2)
	}
	dataRoot, convKey, archiveID := os.Args[1], os.Args[2], os.Args[3]

	chat.SetChatRoot(filepath.Join(dataRoot, "chat"))
	convDir := filepath.Join(dataRoot, "chat", convKey)
	oldMessagesPath := filepath.Join(convDir, "messages.md")
	oldUploadsDir := filepath.Join(convDir, "uploads")
	sessionsDir := filepath.Join(convDir, "sessions")
	newSessionPath := filepath.Join(sessionsDir, archiveID+".md")
	newUploadsDir := filepath.Join(sessionsDir, archiveID+".uploads")

	// Sanity checks.
	if _, err := os.Stat(oldMessagesPath); err != nil {
		fmt.Fprintf(os.Stderr, "archive: no messages.md at %s: %v\n", oldMessagesPath, err)
		os.Exit(1)
	}
	if _, err := os.Stat(sessionsDir); err == nil {
		fmt.Fprintf(os.Stderr, "archive: sessions/ already exists at %s; refusing to migrate\n", sessionsDir)
		os.Exit(1)
	}

	// Pair-key parse: split conv-key into the two member ids so we can
	// reuse chat package's API which keys by (a, b).
	a, b, found := strings.Cut(convKey, "_")
	if !found || a == "" || b == "" {
		fmt.Fprintf(os.Stderr, "archive: bad conv-key %q (need <a>_<b>)\n", convKey)
		os.Exit(1)
	}

	// Read + decode the existing transcript via the chat package's
	// canonical parser, so the 13-hyphen separator + backslash escapes
	// don't bite us.
	data, err := os.ReadFile(oldMessagesPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "archive: read:", err)
		os.Exit(1)
	}
	msgs := decodeViaChat(data)
	fmt.Printf("read %d messages from %s\n", len(msgs), oldMessagesPath)

	// Build the oldID -> newID rewrite map. The old IDs are 6-hex
	// strings; the new IDs are <archive-id>_<n>, 1-based.
	rewrite := make(map[string]string, len(msgs))
	for i := range msgs {
		oldID := msgs[i].ID
		newID := fmt.Sprintf("%s_%d", archiveID, i+1)
		rewrite[oldID] = newID
	}

	// Rewrite MSG_ refs in bodies + image URLs. Sort old IDs by length
	// (longest first) so a shorter id can't accidentally substring-match
	// a longer one. With 6-hex ids they're all the same length, but
	// this keeps the routine robust for re-runs / future schemes.
	oldIDs := make([]string, 0, len(rewrite))
	for k := range rewrite {
		oldIDs = append(oldIDs, k)
	}
	sort.Slice(oldIDs, func(i, j int) bool { return len(oldIDs[i]) > len(oldIDs[j]) })

	// Tokens that must NOT collide inside other text. We match on word
	// boundaries (same shape as chat_msgref.go) so MSG_<oldid> only
	// rewrites as a standalone token.
	msgTokenRe := regexp.MustCompile(`\bMSG_([0-9A-F]{6})\b`)

	// Image URLs gain the session-id segment.
	// Old: /chat/uploads/<conv>/<file>
	// New: /chat/uploads/<conv>/<archive-id>/<file>
	uploadRe := regexp.MustCompile(`(/chat/uploads/[A-Za-z0-9_-]+)/`)
	uploadRepl := fmt.Sprintf("$1/%s/", archiveID)

	refRewrites, imgRewrites := 0, 0
	for i := range msgs {
		body := msgs[i].Body
		body = msgTokenRe.ReplaceAllStringFunc(body, func(m string) string {
			old := strings.TrimPrefix(m, "MSG_")
			if newID, ok := rewrite[old]; ok {
				refRewrites++
				return "MSG_" + newID
			}
			return m
		})
		before := body
		body = uploadRe.ReplaceAllString(body, uploadRepl)
		if body != before {
			imgRewrites++
		}
		msgs[i].Body = body
		msgs[i].ID = rewrite[msgs[i].ID]
	}
	fmt.Printf("rewrote %d MSG_ refs and %d image URL(s) in bodies\n", refRewrites, imgRewrites)

	// Write the session transcript via the chat package's encoder.
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "archive: mkdir sessions:", err)
		os.Exit(1)
	}
	out := encodeViaChat(msgs)
	if err := os.WriteFile(newSessionPath, []byte(out), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "archive: write session:", err)
		os.Exit(1)
	}
	fmt.Printf("wrote %d messages to %s\n", len(msgs), newSessionPath)

	// Move uploads dir.
	if _, err := os.Stat(oldUploadsDir); err == nil {
		if err := os.Rename(oldUploadsDir, newUploadsDir); err != nil {
			fmt.Fprintln(os.Stderr, "archive: rename uploads:", err)
			os.Exit(1)
		}
		fmt.Printf("moved %s -> %s\n", oldUploadsDir, newUploadsDir)
	}

	// Remove the old messages.md (its content is now in the session file).
	if err := os.Remove(oldMessagesPath); err != nil {
		fmt.Fprintln(os.Stderr, "archive: remove old messages.md:", err)
		os.Exit(1)
	}

	// Seed an empty current session for today, so the conv's default
	// (newest) session is the new one, not the archive.
	today := time.Now().UTC().Format("2006-01-02")
	if today == archiveID {
		fmt.Printf("note: today (%s) == archive id; not seeding a new empty session\n", today)
	} else {
		currentPath := filepath.Join(sessionsDir, today+".md")
		if _, err := os.Stat(currentPath); err == nil {
			fmt.Printf("note: %s already exists; not overwriting\n", currentPath)
		} else if err := os.WriteFile(currentPath, []byte(""), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "archive: seed current:", err)
			os.Exit(1)
		} else {
			fmt.Printf("seeded empty %s as the new current session\n", currentPath)
		}
	}

	// Silence the unused-import linter; a + b are validated above but
	// the chat-package functions (which key by (a, b)) aren't called
	// directly here — this tool talks to the filesystem directly so it
	// can do the rename + remove atomically alongside the parse/encode.
	_, _ = a, b
	fmt.Println("done.")
}

// decodeViaChat parses a transcript using a thin adapter — the chat
// package's decoder is unexported, so we re-implement the same
// chatSep / MSG_ / from / date / blank / body shape here. Kept in
// lockstep with chat_store.go by structural comment.
func decodeViaChat(data []byte) []chat.ChatMessage {
	// We don't have access to chat.decodeChatFile (unexported). Use a
	// minimal parser that mirrors its behavior: split on chatSep, then
	// for each piece, MSG_ line then from:/date:/blank/body.
	const sep = "\n\n-------------\n"
	pieces := strings.Split(string(data), sep)
	var out []chat.ChatMessage
	for _, piece := range pieces {
		if strings.TrimSpace(piece) == "" {
			continue
		}
		out = append(out, decodeOne(piece))
	}
	return out
}

func decodeOne(piece string) chat.ChatMessage {
	lines := strings.Split(piece, "\n")
	var msg chat.ChatMessage
	i := 0
	if i < len(lines) && strings.HasPrefix(lines[i], "MSG_") {
		msg.ID = strings.TrimPrefix(lines[i], "MSG_")
		i++
	}
	for ; i < len(lines); i++ {
		if lines[i] == "" {
			break
		}
		key, val, _ := strings.Cut(lines[i], ": ")
		switch key {
		case "from":
			msg.From = val
		case "date":
			if t, err := time.Parse(time.RFC3339, val); err == nil {
				msg.At = t
			}
		}
	}
	bodyLines := lines[i+1:]
	for j, line := range bodyLines {
		bodyLines[j] = unescapeBodyLine(line)
	}
	msg.Body = strings.Join(bodyLines, "\n")
	return msg
}

// encodeViaChat re-emits the messages in the same byte-for-byte shape
// the chat package writes. Mirrors chat_store.go's encodeChatBlock /
// chatStoredForm.
func encodeViaChat(msgs []chat.ChatMessage) string {
	var b strings.Builder
	const sep = "\n\n-------------\n"
	for i, m := range msgs {
		if i > 0 {
			b.WriteString(sep)
		}
		bodyLines := strings.Split(m.Body, "\n")
		for j, line := range bodyLines {
			bodyLines[j] = escapeBodyLine(line)
		}
		fmt.Fprintf(&b, "MSG_%s\nfrom: %s\ndate: %s\n\n%s",
			m.ID, m.From, m.At.UTC().Format(time.RFC3339),
			strings.Join(bodyLines, "\n"))
	}
	return b.String()
}

// escapeBodyLine / unescapeBodyLine mirror the chat package's
// separator-collision protection.
var (
	sepEscapeRe   = regexp.MustCompile(`^\\*-------------$`)
	sepUnescapeRe = regexp.MustCompile(`^\\+-------------$`)
)

func escapeBodyLine(line string) string {
	if sepEscapeRe.MatchString(line) {
		return `\` + line
	}
	return line
}

func unescapeBodyLine(line string) string {
	if sepUnescapeRe.MatchString(line) {
		return line[1:]
	}
	return line
}
