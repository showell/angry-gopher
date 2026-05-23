// Chat storage + live-notify layer. A conversation between two players
// is one append-only `.md` file, kept deliberately human-readable. Each
// message is a block: a MSG_<hash> id line, a from/date header, a blank
// line, then the message body as VERBATIM markdown. Blocks are joined by
// chatSep ("\n\n-------------\n", a 13-hyphen rule); a body line that
// would itself be 13 hyphens gets one extra backslash on write, stripped
// back on read (see escapeBodyLine), so it can't be mistaken for the
// separator.
//
// One directory per conversation, keyed by the pair (see chatPairKey):
// messages.md is the transcript both participants append to, and
// uploads/ holds its image uploads — so a conversation is one
// self-contained, access-controllable unit. Appends are serialized by
// chatMu — a single-process server makes a mutex sufficient, and it's
// needed because a long post can exceed PIPE_BUF, past which POSIX
// append-atomicity no longer holds.
//
// chatMu also guards the in-memory subscriber registry, so an SSE
// client can read the current backlog and subscribe for future
// messages atomically: any concurrent append is serialized either
// fully before (and thus in the backlog) or fully after (and thus
// delivered on the channel) — never lost in the gap.
package views

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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

// ChatMessage is one stored message. Hash is the 6-hex id written as the
// MSG_ line atop the block and used for MSG_ references.
type ChatMessage struct {
	From string
	At   time.Time
	Body string
	Hash string
}

// chatEvent is a message plus its 0-based index in the conversation,
// used as the SSE event id so a reconnecting client can resume.
type chatEvent struct {
	Index int
	Msg   ChatMessage
}

var (
	chatMu   sync.Mutex
	chatSubs = map[string]map[chan chatEvent]struct{}{}
)

// chatPairKey is the canonical conversation key: the two user ids sorted
// numerically, joined by "_" (e.g. "1_2"). Ids are digits-only, so the
// key always splits back unambiguously.
func chatPairKey(a, b string) string {
	if atoiOr0(a) <= atoiOr0(b) {
		return a + "_" + b
	}
	return b + "_" + a
}

// chatConvDir is a conversation's own directory; everything for the pair
// (messages + uploads) lives under it, so a conversation is one
// self-contained, ACL-able unit.
func chatConvDir(a, b string) string {
	return filepath.Join(ChatDataRoot, chatPairKey(a, b))
}

// chatMessagesPath is the conversation transcript file.
func chatMessagesPath(a, b string) string {
	return filepath.Join(chatConvDir(a, b), "messages.md")
}

// chatUploadsDir is where a conversation's image uploads live.
func chatUploadsDir(a, b string) string {
	return filepath.Join(chatConvDir(a, b), "uploads")
}

// ChatUploadsDirForKey is the uploads dir addressed by a conversation
// key (used by the serving path, which knows the key, not the pair).
func ChatUploadsDirForKey(key string) string {
	return filepath.Join(ChatDataRoot, key, "uploads")
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

// chatMsgHash is a message's stable 6-hex-uppercase id. Derived from the
// (immutable, append-only) index + author + timestamp + body; computed
// once at append time and then stored as the block's MSG_ line.
func chatMsgHash(index int, msg ChatMessage) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%d\x00%s\x00%s\x00%s",
		index, msg.From, msg.At.UTC().Format(time.RFC3339), msg.Body)))
	return strings.ToUpper(hex.EncodeToString(sum[:3]))
}

// encodeChatBlock renders one message to its on-disk block: the MSG_
// hash line, the from/date header, a blank line, then the verbatim
// markdown body. No separator — chatStoredForm adds that.
func encodeChatBlock(msg ChatMessage) string {
	bodyLines := strings.Split(msg.Body, "\n")
	for i, line := range bodyLines {
		bodyLines[i] = escapeBodyLine(line)
	}
	return fmt.Sprintf("MSG_%s\nfrom: %s\ndate: %s\n\n%s",
		msg.Hash, msg.From, msg.At.UTC().Format(time.RFC3339),
		strings.Join(bodyLines, "\n"))
}

// chatStoredForm is exactly what message `index` contributes to the file:
// its block, preceded by the separator for every message after the
// first. Concatenated over a conversation these reproduce the file, so
// the Transcript view (built from these) mirrors storage byte-for-byte.
func chatStoredForm(index int, msg ChatMessage) string {
	if index == 0 {
		return encodeChatBlock(msg)
	}
	return chatSep + encodeChatBlock(msg)
}

// decodeChatFile parses a whole conversation file into messages.
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

// decodeChatBlock parses one block (MSG_ hash line, header lines, blank,
// body).
func decodeChatBlock(piece string) ChatMessage {
	lines := strings.Split(piece, "\n")
	var msg ChatMessage
	i := 0
	if i < len(lines) && strings.HasPrefix(lines[i], "MSG_") {
		msg.Hash = strings.TrimPrefix(lines[i], "MSG_")
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

// readChatFileLocked reads + parses a conversation file. Caller holds
// chatMu. A missing file is an empty conversation.
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

// ReadChatMessages returns the whole conversation between two players.
func ReadChatMessages(a, b string) ([]ChatMessage, error) {
	chatMu.Lock()
	defer chatMu.Unlock()
	return readChatFileLocked(chatMessagesPath(a, b))
}

// AppendChatMessage stores a message from `from` to the partner id and
// publishes it to any live subscribers. The conversation is keyed by the
// two ids; the message records the sender's display name. Returns the
// stored message (with its normalized timestamp).
func AppendChatMessage(from User, partnerID, body string) (ChatMessage, error) {
	key := chatPairKey(from.ID, partnerID)
	path := chatMessagesPath(from.ID, partnerID)
	msg := ChatMessage{From: from.Name, At: time.Now().UTC(), Body: body}

	chatMu.Lock()
	defer chatMu.Unlock()

	existing, err := readChatFileLocked(path)
	if err != nil {
		return msg, err
	}
	index := len(existing)
	msg.Hash = chatMsgHash(index, msg)

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

	evt := chatEvent{Index: index, Msg: msg}
	for ch := range chatSubs[key] {
		select {
		case ch <- evt:
		default: // slow subscriber; it will replay on reconnect
		}
	}
	return msg, nil
}

// OpenChatStream atomically snapshots the backlog from `since` onward
// and registers a subscriber for future messages. The returned cancel
// must be called to unsubscribe (and close the channel).
func OpenChatStream(a, b string, since int) (backlog []chatEvent, ch <-chan chatEvent, cancel func()) {
	key := chatPairKey(a, b)
	out := make(chan chatEvent, 32)

	chatMu.Lock()
	defer chatMu.Unlock()

	all, _ := readChatFileLocked(chatMessagesPath(a, b))
	for i := since; i >= 0 && i < len(all); i++ {
		backlog = append(backlog, chatEvent{Index: i, Msg: all[i]})
	}
	if chatSubs[key] == nil {
		chatSubs[key] = map[chan chatEvent]struct{}{}
	}
	chatSubs[key][out] = struct{}{}

	cancel = func() {
		chatMu.Lock()
		defer chatMu.Unlock()
		if subs := chatSubs[key]; subs != nil {
			if _, ok := subs[out]; ok {
				delete(subs, out)
				close(out)
			}
			if len(subs) == 0 {
				delete(chatSubs, key)
			}
		}
	}
	return backlog, out, cancel
}
