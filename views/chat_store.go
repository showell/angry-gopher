// Chat storage + live-notify layer. A conversation between two players
// is one append-only `.md` file, kept deliberately human-readable: a
// short header (from/date), a blank line, then the message body as
// VERBATIM markdown, terminated by a `\----------` separator line. The
// leading backslash makes the separator render as literal text (not an
// <hr>) in any markdown viewer; a body line that would collide with it
// gets one extra backslash on write, stripped back on read.
//
// One file per conversation keyed by the sorted pair of usernames, so
// both participants read and append to the same file. Appends are
// serialized by chatMu — a single-process server makes a mutex
// sufficient, and it's needed because a long post can exceed PIPE_BUF,
// past which POSIX append-atomicity no longer holds.
//
// chatMu also guards the in-memory subscriber registry, so an SSE
// client can read the current backlog and subscribe for future
// messages atomically: any concurrent append is serialized either
// fully before (and thus in the backlog) or fully after (and thus
// delivered on the channel) — never lost in the gap.
package views

import (
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

// chatSep is the message separator line: a backslash then ten hyphens.
const chatSep = `\----------`

// sepLineRe matches a line of one-or-more backslashes followed by
// exactly ten hyphens — the separator and its escaped forms. A bare
// `----------` (a real markdown rule) has zero backslashes and is left
// untouched.
var sepLineRe = regexp.MustCompile(`^\\+----------$`)

// ChatMessage is one stored message.
type ChatMessage struct {
	From string
	At   time.Time
	Body string
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

// chatPairKey is the canonical conversation key: the two usernames
// sorted, joined by `__` (impossible inside a username, so unambiguous).
func chatPairKey(a, b string) string {
	if a <= b {
		return a + "__" + b
	}
	return b + "__" + a
}

// chatPath is the conversation file for a pair.
func chatPath(a, b string) string {
	return filepath.Join(ChatDataRoot, chatPairKey(a, b)+".md")
}

// escapeBodyLine protects a body line that would collide with the
// separator by prepending a backslash.
func escapeBodyLine(line string) string {
	if sepLineRe.MatchString(line) {
		return `\` + line
	}
	return line
}

// unescapeBodyLine reverses escapeBodyLine.
func unescapeBodyLine(line string) string {
	if sepLineRe.MatchString(line) {
		return line[1:]
	}
	return line
}

// encodeChatBlock renders one message to its on-disk block.
func encodeChatBlock(msg ChatMessage) string {
	bodyLines := strings.Split(msg.Body, "\n")
	for i, line := range bodyLines {
		bodyLines[i] = escapeBodyLine(line)
	}
	return fmt.Sprintf("from: %s\ndate: %s\n\n%s\n%s\n",
		msg.From, msg.At.UTC().Format(time.RFC3339),
		strings.Join(bodyLines, "\n"), chatSep)
}

// decodeChatFile parses a whole conversation file into messages.
func decodeChatFile(data []byte) []ChatMessage {
	text := string(data)
	// Each block ends with "\n" + chatSep + "\n"; splitting on that
	// literal yields one piece per message plus a trailing "".
	pieces := strings.Split(text, "\n"+chatSep+"\n")
	var out []ChatMessage
	for _, piece := range pieces {
		if strings.TrimSpace(piece) == "" {
			continue
		}
		out = append(out, decodeChatBlock(piece))
	}
	return out
}

// decodeChatBlock parses one block (header lines, blank, body).
func decodeChatBlock(piece string) ChatMessage {
	lines := strings.Split(piece, "\n")
	var msg ChatMessage
	i := 0
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
	return readChatFileLocked(chatPath(a, b))
}

// AppendChatMessage stores a message from `from` to `partner` and
// publishes it to any live subscribers. Returns the stored message
// (with its normalized timestamp).
func AppendChatMessage(from, partner, body string) (ChatMessage, error) {
	key := chatPairKey(from, partner)
	path := chatPath(from, partner)
	msg := ChatMessage{From: from, At: time.Now().UTC(), Body: body}

	chatMu.Lock()
	defer chatMu.Unlock()

	existing, err := readChatFileLocked(path)
	if err != nil {
		return msg, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return msg, err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return msg, err
	}
	if _, err := f.WriteString(encodeChatBlock(msg)); err != nil {
		f.Close()
		return msg, err
	}
	if err := f.Close(); err != nil {
		return msg, err
	}

	evt := chatEvent{Index: len(existing), Msg: msg}
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

	all, _ := readChatFileLocked(chatPath(a, b))
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
