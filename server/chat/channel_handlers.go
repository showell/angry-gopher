// Channel routes. /channel/<name>/{,<topic>{,/stream,/send,/pin,/unpin,
// /upload,/uploads/<file>},new}. Mirror the /chat/c/<conv>/... handlers
// — the difference is which Conv constructor we resolve to. Once we
// have a Conv, the rest of the chat machinery is shared.
package chat

import (
	"angry-gopher/server/users"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func todayDateSlug() string { return time.Now().UTC().Format("2006-01-02") }

func respondNewTopic(w http.ResponseWriter, conv, sid string) {
	_ = json.NewEncoder(w).Encode(map[string]string{"conv": conv, "sid": sid})
}

// channelPathConv resolves the {channel} path param to a Conv if the
// caller is a member; ok=false means a response has already been
// written. Mirrors chatPathParticipant's contract.
func channelPathConv(w http.ResponseWriter, r *http.Request) (user users.User, c Conv, ok bool) {
	user = users.CurrentUser(r)
	name := r.PathValue("channel")
	c, ok = ChannelConv(name, user.ID)
	if !ok {
		http.NotFound(w, r) // don't reveal the channel exists
	}
	return
}

// channelPathTopic is channelPathConv plus validation of {topic}.
func channelPathTopic(w http.ResponseWriter, r *http.Request) (user users.User, c Conv, sid string, ok bool) {
	user, c, ok = channelPathConv(w, r)
	if !ok {
		return
	}
	sid = r.PathValue("topic")
	if !validSessionID(sid) {
		http.NotFound(w, r)
		ok = false
		return
	}
	return
}

// HandleChannelConv serves /channel/<name>: redirects to the default
// topic. If the channel has no topics yet, lands on the date-of-today
// topic (auto-created on first post, same as DMs).
func HandleChannelConv(w http.ResponseWriter, r *http.Request) {
	_, c, ok := channelPathConv(w, r)
	if !ok {
		return
	}
	sid := c.DefaultSession()
	if sid == "" {
		sid = todayDateSlug()
	}
	http.Redirect(w, r, "/channel/"+c.Key+"/"+url.PathEscape(sid), http.StatusSeeOther)
}

// HandleChannelPage serves /channel/<name>/<topic>: renders one topic.
func HandleChannelPage(w http.ResponseWriter, r *http.Request) {
	user, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	renderConversation(w, user, c, sid)
}

// HandleChannelStream serves the per-topic SSE.
func HandleChannelStream(w http.ResponseWriter, r *http.Request) {
	_, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	since := parseSince(r)
	serveChatStream(w, r, c, sid, since)
}

// HandleChannelSend posts a message to a topic.
func HandleChannelSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxChatMessageBytes)
	if err := r.ParseForm(); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "message too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	markdown := strings.TrimSpace(r.FormValue("markdown"))
	cid := strings.TrimSpace(r.FormValue("cid"))
	if markdown == "" {
		http.Error(w, "empty message", http.StatusBadRequest)
		return
	}
	if _, err := c.AppendMessage(user, sid, markdown, cid); err != nil {
		http.Error(w, "append: "+err.Error(), http.StatusInternalServerError)
		return
	}
	users.TouchUser(user.ID)
	if r.Header.Get("X-Chat-Async") != "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, c.topicURL(sid), http.StatusSeeOther)
}

// HandleChannelPin toggles the caller's per-user pin for a topic.
func HandleChannelPin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	SetSessionPinned(user.ID, c.Key, sid, !strings.HasSuffix(r.URL.Path, "/unpin"))
	w.WriteHeader(http.StatusNoContent)
}

// HandleChannelNewTopic creates a new topic in the channel, seeding it
// with a "hi" so the file exists on disk and the topic shows up in the
// sidebar via the topic-added SSE.
func HandleChannelNewTopic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, c, ok := channelPathConv(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	topic := strings.TrimSpace(r.FormValue("topic"))
	if !validSessionID(topic) {
		http.Error(w, "Topic must be letters, digits, and hyphens only — no spaces, underscores, or punctuation.", http.StatusBadRequest)
		return
	}
	if topic == "new" {
		http.Error(w, `"new" is reserved — pick another topic name.`, http.StatusBadRequest)
		return
	}
	if c.SessionExists(topic) {
		http.Error(w, "That topic already exists.", http.StatusConflict)
		return
	}
	if _, err := c.AppendMessage(user, topic, "hi", ""); err != nil {
		http.Error(w, "create topic: "+err.Error(), http.StatusInternalServerError)
		return
	}
	users.TouchUser(user.ID)
	w.Header().Set("Content-Type", "application/json")
	respondNewTopic(w, c.Key, topic)
}
