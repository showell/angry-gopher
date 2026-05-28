// Chat storage + live-notify layer. A conversation between two players
// lives in one directory under {ChatDataRoot}/<conv-key>/; sessions
// within that conversation are individual files under sessions/. Each
// session file is the same append-only `.md` shape we've always used —
// a block per message: a MSG_<id> id line, a from/date header, a blank
// line, then the message body as VERBATIM markdown. Blocks are joined
// by chatSep ("\n\n-------------\n", a 13-hyphen rule); a body line
// that would itself be 13 hyphens gets one extra backslash on write,
// stripped back on read (see escapeBodyLine), so it can't be mistaken
// for the separator.
//
// One directory per conversation, keyed by the pair (see chatPairKey):
//
//	<root>/<conv>/sessions/<session-id>.md         — the session transcript
//	<root>/<conv>/sessions/<session-id>.uploads/   — its image uploads
//
// Sessions are identified by date-prefixed slugs (e.g. "2026-05-23")
// so they sort lexicographically by recency. The newest session is the
// default landing target; a per-user pointer (chat_state.go) tracks
// what each user was last looking at.
//
// Message ids are MSG_<session-id>_<n>, where n is the 1-based index
// within the session. The id is computed at append time and stored as
// the block's MSG_ line. This means session-ids may NOT contain
// underscores (the trailing _<n> would be ambiguous); date-prefixed
// slugs satisfy that naturally.
//
// Appends are serialized by chatMu — a single-process server makes a
// mutex sufficient, and it's needed because a long post can exceed
// PIPE_BUF, past which POSIX append-atomicity no longer holds.
//
// chatMu also guards the in-memory subscriber registry, so an SSE
// client can read the current backlog and subscribe for future
// messages atomically: any concurrent append is serialized either
// fully before (and thus in the backlog) or fully after (and thus
// delivered on the channel) — never lost in the gap. The subscriber
// registry is keyed by (conv, session) so a subscriber on session X
// doesn't see messages appended to session Y in the same conv.
package chat

import (
	"angry-gopher/server/users"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// ChatDataRoot is the on-disk root for all conversation files, set by
// SetChatRoot at startup. Sibling of the game/puzzle tree so chat is a
// self-contained subtree (easy to back up or migrate on its own).
var ChatDataRoot = "games/lynrummy/chat-data"

// SetChatRoot points conversation storage at the configured dir.
func SetChatRoot(root string) { ChatDataRoot = root }

// chatSep separates messages in the file: a blank line, a 13-hyphen
// rule, then a newline. Concatenating each message's stored form (the
// block, preceded by this for all but the first) reproduces the file
// byte-for-byte, which is what the Transcript view shows.
const chatSep = "\n\n-------------\n"

// A body line of exactly 13 hyphens would collide with the separator, so
// it's escaped with a leading backslash on write (and an already-
// backslashed run of them gets one more); the read path strips one back.
var (
	sepEscapeRe   = regexp.MustCompile(`^\\*-------------$`)
	sepUnescapeRe = regexp.MustCompile(`^\\+-------------$`)
)

// ChatMessage is one stored message. ID is the full MSG_ id written as
// the MSG_ line atop the block, e.g. "2026-05-23_42" for message #42
// in session 2026-05-23, and is what MSG_ references resolve to.
type ChatMessage struct {
	From string
	At   time.Time
	Body string
	ID   string
}

// chatEvent is a message plus its 0-based index in the session, used
// as the SSE event id so a reconnecting client can resume. Cid is the
// sender's client-correlation id, carried on the LIVE broadcast only
// (never stored, so it's absent on backlog/replay) — it lets the
// sending client confirm its message round-tripped (saved + echoed).
type chatEvent struct {
	Index int
	Msg   ChatMessage
	Cid   string
}

var (
	chatMu sync.Mutex
	// chatSubs is keyed by "<conv-key>/<session-id>" so subscribers on
	// session X don't see messages appended to session Y in the same conv.
	chatSubs = map[string]map[chan chatEvent]struct{}{}
)

// chatPairKey is the canonical conversation key: the two user ids sorted
// numerically, joined by "_" (e.g. "1_2"). Ids are digits-only, so the
// key always splits back unambiguously.
func chatPairKey(a, b string) string {
	if users.AtoiOr0(a) <= users.AtoiOr0(b) {
		return a + "_" + b
	}
	return b + "_" + a
}

// chatConvDir is a conversation's own directory; everything for the pair
// (sessions + their uploads) lives under it, so a conversation is one
// self-contained, ACL-able unit.
func chatConvDir(a, b string) string {
	return filepath.Join(ChatDataRoot, chatPairKey(a, b))
}

// chatSessionsDir is where a conversation's session files live.
func chatSessionsDir(a, b string) string {
	return filepath.Join(chatConvDir(a, b), "sessions")
}

// chatSessionPath is the on-disk transcript for one session of a
// conversation.
func chatSessionPath(a, b, sessionID string) string {
	return filepath.Join(chatSessionsDir(a, b), sessionID+".md")
}

// chatSessionUploadsDir is where a session's image uploads live — a
// sidecar dir alongside the session file, so each session owns its
// own uploads cleanly.
func chatSessionUploadsDir(a, b, sessionID string) string {
	return filepath.Join(chatSessionsDir(a, b), sessionID+".uploads")
}

// ChatSessionUploadsDirForKey is the uploads dir addressed by a
// conversation key (used by the serving path, which knows the key,
// not the pair).
func ChatSessionUploadsDirForKey(key, sessionID string) string {
	return filepath.Join(ChatDataRoot, key, "sessions", sessionID+".uploads")
}

// ChatKeyParticipant reports whether user id `user` is in the
// conversation named by `key`, and that `key` is in canonical form. The
// serving path uses this to enforce per-conversation access on images.
func ChatKeyParticipant(key, user string) bool {
	x, y, found := strings.Cut(key, "_")
	if !found || x == "" || y == "" {
		return false
	}
	if chatPairKey(x, y) != key {
		return false
	}
	return user == x || user == y
}

// ListChatSessions returns every session id for a conversation, sorted
// newest-first (which, given date-prefixed slugs, means lexicographic
// descending). An empty list = no sessions on disk yet.
func ListChatSessions(a, b string) []string {
	entries, err := os.ReadDir(chatSessionsDir(a, b))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			continue // .uploads dirs
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		out = append(out, strings.TrimSuffix(name, ".md"))
	}
	sort.Sort(sort.Reverse(sort.StringSlice(out)))
	return out
}

// DefaultChatSession returns the newest session id for a conversation,
// or "" if none exist yet.
func DefaultChatSession(a, b string) string {
	if list := ListChatSessions(a, b); len(list) > 0 {
		return list[0]
	}
	return ""
}

// ChatSessionExists reports whether the given session id has a file
// on disk for this conversation pair.
func ChatSessionExists(a, b, sessionID string) bool {
	_, err := os.Stat(chatSessionPath(a, b, sessionID))
	return err == nil
}

// chatMsgID is the message's stable id: the session id, an underscore,
// and the 1-based index of this message within that session. Stored as
// the block's MSG_ line.
func chatMsgID(sessionID string, index int) string {
	return fmt.Sprintf("%s_%d", sessionID, index+1)
}

// escapeBodyLine protects a body line that would collide with the
// separator by prepending a backslash.
func escapeBodyLine(line string) string {
	if sepEscapeRe.MatchString(line) {
		return `\` + line
	}
	return line
}

// unescapeBodyLine reverses escapeBodyLine.
func unescapeBodyLine(line string) string {
	if sepUnescapeRe.MatchString(line) {
		return line[1:]
	}
	return line
}

// encodeChatBlock renders one message to its on-disk block: the MSG_
// id line, the from/date header, a blank line, then the verbatim
// markdown body. No separator — chatStoredForm adds that.
func encodeChatBlock(msg ChatMessage) string {
	bodyLines := strings.Split(msg.Body, "\n")
	for i, line := range bodyLines {
		bodyLines[i] = escapeBodyLine(line)
	}
	return fmt.Sprintf("MSG_%s\nfrom: %s\ndate: %s\n\n%s",
		msg.ID, msg.From, msg.At.UTC().Format(time.RFC3339),
		strings.Join(bodyLines, "\n"))
}

// chatStoredForm is exactly what message `index` contributes to the file:
// its block, preceded by the separator for every message after the
// first. Concatenated over a session these reproduce the file, so
// the Transcript view (built from these) mirrors storage byte-for-byte.
func chatStoredForm(index int, msg ChatMessage) string {
	if index == 0 {
		return encodeChatBlock(msg)
	}
	return chatSep + encodeChatBlock(msg)
}

// decodeChatFile parses a whole session file into messages.
func decodeChatFile(data []byte) []ChatMessage {
	text := string(data)
	// Messages are joined by chatSep (no trailing separator), so splitting
	// on it yields one piece per message.
	pieces := strings.Split(text, chatSep)
	var out []ChatMessage
	for _, piece := range pieces {
		if strings.TrimSpace(piece) == "" {
			continue
		}
		out = append(out, decodeChatBlock(piece))
	}
	return out
}

// decodeChatBlock parses one block (MSG_ id line, header lines, blank,
// body).
func decodeChatBlock(piece string) ChatMessage {
	lines := strings.Split(piece, "\n")
	var msg ChatMessage
	i := 0
	if i < len(lines) && strings.HasPrefix(lines[i], "MSG_") {
		msg.ID = strings.TrimPrefix(lines[i], "MSG_")
		i++
	}
	for ; i < len(lines); i++ {
		if lines[i] == "" {
			break // blank line ends the header
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
	bodyLines := lines[i+1:] // everything after the blank
	for j, line := range bodyLines {
		bodyLines[j] = unescapeBodyLine(line)
	}
	msg.Body = strings.Join(bodyLines, "\n")
	return msg
}

// readChatFileLocked reads + parses one session file. Caller holds
// chatMu. A missing file is an empty session.
func readChatFileLocked(path string) ([]ChatMessage, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return decodeChatFile(data), nil
}

// ReadChatSession returns every message in one session of a
// conversation.
func ReadChatSession(a, b, sessionID string) ([]ChatMessage, error) {
	chatMu.Lock()
	defer chatMu.Unlock()
	return readChatFileLocked(chatSessionPath(a, b, sessionID))
}

// AppendChatMessage stores a message from `from` to the partner id,
// writing it to the named session, and publishes it to any live
// subscribers of that (conv, session). Returns the stored message
// (with its normalized timestamp + id).
func AppendChatMessage(from users.User, partnerID, sessionID, body, cid string) (ChatMessage, error) {
	convKey := chatPairKey(from.ID, partnerID)
	subKey := convKey + "/" + sessionID
	path := chatSessionPath(from.ID, partnerID, sessionID)
	msg := ChatMessage{From: from.Name, At: time.Now().UTC(), Body: body}

	chatMu.Lock()
	defer chatMu.Unlock()

	existing, err := readChatFileLocked(path)
	if err != nil {
		return msg, err
	}
	index := len(existing)
	msg.ID = chatMsgID(sessionID, index)

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return msg, err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return msg, err
	}
	if _, err := f.WriteString(chatStoredForm(index, msg)); err != nil {
		f.Close()
		return msg, err
	}
	if err := f.Close(); err != nil {
		return msg, err
	}

	evt := chatEvent{Index: index, Msg: msg, Cid: cid}
	for ch := range chatSubs[subKey] {
		select {
		case ch <- evt:
		default: // slow subscriber; it will replay on reconnect
		}
	}
	return msg, nil
}

// OpenChatStream atomically snapshots one session's backlog from
// `since` onward and registers a subscriber for future messages in
// that session. The returned cancel must be called to unsubscribe
// (and close the channel).
func OpenChatStream(a, b, sessionID string, since int) (backlog []chatEvent, ch <-chan chatEvent, cancel func()) {
	convKey := chatPairKey(a, b)
	subKey := convKey + "/" + sessionID
	out := make(chan chatEvent, 32)

	chatMu.Lock()
	defer chatMu.Unlock()

	all, _ := readChatFileLocked(chatSessionPath(a, b, sessionID))
	for i := since; i >= 0 && i < len(all); i++ {
		backlog = append(backlog, chatEvent{Index: i, Msg: all[i]})
	}
	if chatSubs[subKey] == nil {
		chatSubs[subKey] = map[chan chatEvent]struct{}{}
	}
	chatSubs[subKey][out] = struct{}{}

	cancel = func() {
		chatMu.Lock()
		defer chatMu.Unlock()
		if subs := chatSubs[subKey]; subs != nil {
			if _, ok := subs[out]; ok {
				delete(subs, out)
				close(out)
			}
			if len(subs) == 0 {
				delete(chatSubs, subKey)
			}
		}
	}
	return backlog, out, cancel
}
