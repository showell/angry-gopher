package chat

import (
	"angry-gopher/server/users"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ConvKind discriminates a 1:1 DM from an N-party channel. It's the
// one axis the chat machinery cares about: storage paths, member list,
// SSE plumbing, and recent/images/code fanout are identical across the
// two; only URL space and the two human-readable strings ("X sent you
// a message" vs "X posted to General > topic") differ.
type ConvKind int

const (
	KindDM ConvKind = iota
	KindChannel
)

// Conv is "the thing a topic/transcript lives inside" — abstracts a DM
// pair OR a channel. The pieces every transcript op needs:
//
//   - Kind: DM or channel.
//   - Key: URL-visible address ("1_2" for DMs, "General" for channels).
//     Doubles as the chatSubs / sidebar publish keyspace. DM keys are
//     digits-only by construction; channel names are forbidden from
//     being digits-only (validChannelName), so the namespaces never
//     collide.
//   - Dir: storage root for this conv. Sessions live at
//     <Dir>/sessions/<sid>.md, with .lastauthor + .uploads/ siblings.
//   - Members: sorted subscriber uids. DMs always have two; channels
//     read theirs from a .channel file.
//
// DMs construct via DMConv(a, b); channels via ChannelConv(name) (see
// channels.go). From the point of construction, the rest of the chat
// machinery (append, SSE publish, notify fanout, recent/images/code
// transcripts) doesn't care which kind it is — same code path.
type Conv struct {
	Kind    ConvKind
	Key     string
	Dir     string
	Members []string
}

// baseURL is the conversation's URL root (no topic). chat.js reads it
// from data-conv-base to build /send, /stream, /upload, and cross-
// session refs without branching on Kind.
func (c Conv) baseURL() string {
	if c.Kind == KindChannel {
		return "/channel/" + c.Key
	}
	return "/chat/c/" + c.Key
}

// convKeyBaseURL returns the URL root for a conv addressed by its
// storage key alone. DM keys are "<digits>_<digits>" by construction
// (the only conv keys that contain an underscore — channel names
// exclude "_" per validChannelName), so the shape is a sufficient
// discriminator without rebuilding the full Conv.
func convKeyBaseURL(convKey string) string {
	if strings.Contains(convKey, "_") {
		return "/chat/c/" + convKey
	}
	return "/channel/" + convKey
}

// topicURL is c.baseURL() + "/" + sid — the URL to one topic page.
func (c Conv) topicURL(sid string) string { return c.baseURL() + "/" + sid }

// tabTitleFor is the browser-tab text shown on the conversation page,
// per viewer (DMs need the OTHER party's name).
func (c Conv) tabTitleFor(viewerUID, sid string) string {
	if c.Kind == KindChannel {
		return "#" + c.Key + ": " + sid
	}
	return "Chat w/" + users.GetUserName(c.PartnerOf(viewerUID)) + ": " + sid
}

// notifyText is the human-readable notify-strip line for one new
// message. DMs read as "X sent you a message on <session>"; channels
// read as "X posted to <channel> > <topic>."
func (c Conv) notifyText(from users.User, sid string) string {
	if c.Kind == KindChannel {
		return from.Name + " posted to " + c.Key + " > " + sid + "."
	}
	return from.Name + " sent you a message on " + sid + "."
}

// DMConv builds a Conv for the DM pair (a, b). Key + Dir match the
// historical layout: <ChatDataRoot>/<pair-key>/sessions/<sid>.md.
func DMConv(a, b string) Conv {
	key := chatPairKey(a, b)
	members := []string{a, b}
	sort.Slice(members, func(i, j int) bool {
		return users.AtoiOr0(members[i]) < users.AtoiOr0(members[j])
	})
	return Conv{
		Kind:    KindDM,
		Key:     key,
		Dir:     filepath.Join(ChatDataRoot, key),
		Members: members,
	}
}

// HasMember reports whether uid is a subscriber.
func (c Conv) HasMember(uid string) bool {
	for _, m := range c.Members {
		if m == uid {
			return true
		}
	}
	return false
}

// PartnerOf returns the OTHER member in a DM, or "" if c isn't a 2-party
// DM or uid isn't a member. Channels return "" — there is no single
// partner to address.
func (c Conv) PartnerOf(uid string) string {
	if len(c.Members) != 2 {
		return ""
	}
	if c.Members[0] == uid {
		return c.Members[1]
	}
	if c.Members[1] == uid {
		return c.Members[0]
	}
	return ""
}

// On-disk paths. All sessions for a conv share the sessions/ subdir; a
// session is the .md file plus optional .lastauthor + .uploads/ siblings.

func (c Conv) sessionsDir() string             { return filepath.Join(c.Dir, "sessions") }
func (c Conv) SessionPath(sid string) string   { return filepath.Join(c.sessionsDir(), sid+".md") }
func (c Conv) LastAuthorPath(sid string) string {
	return filepath.Join(c.sessionsDir(), sid+".lastauthor")
}
func (c Conv) UploadsDir(sid string) string {
	return filepath.Join(c.sessionsDir(), sid+".uploads")
}

// ListSessions returns every session id in this conv, alphabetical
// (ascending). Empty list = no sessions on disk yet.
func (c Conv) ListSessions() []string {
	entries, err := os.ReadDir(c.sessionsDir())
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
	sort.Strings(out)
	return out
}

// DefaultSession returns the alphabetically-first session id, or "" if
// the conv has none on disk.
func (c Conv) DefaultSession() string {
	if list := c.ListSessions(); len(list) > 0 {
		return list[0]
	}
	return ""
}

// PreferredDefaultSession is the topic to land on when the viewer
// hasn't picked one yet. It prefers ChitChat (the convention for
// ongoing free-form chat in both DMs and channels) when that topic
// exists, otherwise falls back to DefaultSession. Returns "" only
// when the conv has no topics at all on disk.
func (c Conv) PreferredDefaultSession() string {
	if c.SessionExists("ChitChat") {
		return "ChitChat"
	}
	return c.DefaultSession()
}

// SessionExists reports whether sid has a transcript file on disk.
func (c Conv) SessionExists(sid string) bool {
	_, err := os.Stat(c.SessionPath(sid))
	return err == nil
}

// LastAuthor returns the uid of the most recent author of a session,
// or "" if the companion file is missing or unreadable.
func (c Conv) LastAuthor(sid string) string {
	data, err := os.ReadFile(c.LastAuthorPath(sid))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// ReadSession returns the parsed messages of one session, or an error.
func (c Conv) ReadSession(sid string) ([]ChatMessage, error) {
	chatMu.Lock()
	defer chatMu.Unlock()
	return readChatFileLocked(c.SessionPath(sid))
}

// RawSession returns the literal on-disk transcript bytes for one
// session — the append-only MSG_/from:/date: .md file, unparsed and
// undecoded. This is the durable source of truth that BOTH the UI's "t"
// raw-view tab and the fetch_prod_transcript backup client serve, so an
// interactive export and an automated backup are byte-for-byte the same.
// Read under chatMu so it never observes a half-written append.
func (c Conv) RawSession(sid string) ([]byte, error) {
	chatMu.Lock()
	defer chatMu.Unlock()
	return os.ReadFile(c.SessionPath(sid))
}

// AppendMessage stores a message in the named session, fans out to
// every live subscriber, and pings the cross-page user-attention layer
// (notify + recent + images + code, plus a sidebar topic-added on the
// session's first message). Same code path for DMs and channels — the
// only difference is which subscribers Members lists.
func (c Conv) AppendMessage(from users.User, sid, markdown, cid string) (ChatMessage, error) {
	subKey := c.Key + "/" + sid
	path := c.SessionPath(sid)
	msg := ChatMessage{From: from.Name, At: nowFn(), Markdown: markdown}

	chatMu.Lock()
	defer chatMu.Unlock()

	existing, err := readChatFileLocked(path)
	if err != nil {
		return msg, err
	}
	index := len(existing)
	msg.ID = chatMsgID(sid, index)

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

	// Last-author companion. Best-effort — Recent degrades to "no author
	// shown" if it fails, but the message itself is durable.
	_ = os.WriteFile(c.LastAuthorPath(sid), []byte(from.ID), 0o644)

	evt := chatEvent{Index: index, Msg: msg, Cid: cid}
	for ch := range chatSubs[subKey] {
		select {
		case ch <- evt:
		default: // slow subscriber; it will replay on reconnect
		}
	}
	c.fanoutMessage(from, sid, msg, index)
	return msg, nil
}

// OpenStream registers an SSE subscriber for one session and returns
// the backlog from `since` plus a live channel.
func (c Conv) OpenStream(sid string, since int) (backlog []chatEvent, ch <-chan chatEvent, cancel func()) {
	subKey := c.Key + "/" + sid
	out := make(chan chatEvent, 32)

	chatMu.Lock()
	defer chatMu.Unlock()

	all, _ := readChatFileLocked(c.SessionPath(sid))
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

// nowFn is time.Now indirected so tests could swap it; not yet used.
var nowFn = func() time.Time { return time.Now().UTC() }

// fanoutMessage publishes to every cross-page user-attention stream:
// notify (status strip), recent (Recent page), images / code (per-user
// transcripts), and a sidebar topic-added on the session's first
// message. Sender is INCLUDED in each fan-out — the notify-strip
// suppression on the open feed lives in notify.js, and recent/images/
// code want every member to see the row.
func (c Conv) fanoutMessage(from users.User, sid string, msg ChatMessage, index int) {
	notifyEvt := notifyEvent{
		Conv:    c.Key,
		Session: sid,
		Text:    c.notifyText(from, sid),
		LinkURL: c.topicURL(sid),
	}
	for _, uid := range c.Members {
		notifyBus.publish(uid, notifyEvt)
	}
	publishRecentForConv(c, sid, msg.At, from.ID, msg.Markdown)
	publishImagesForConv(c, sid, msg)
	publishCodeForConv(c, sid, msg)
	if index == 0 {
		publishTopicAddedForConv(c, sid)
	}
}
