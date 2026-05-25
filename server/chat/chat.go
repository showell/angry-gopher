// Chat surface: a private one-on-one conversation page, a send
// endpoint, and a Server-Sent-Events stream for live delivery.
//
// Privacy is structural: a conversation is always keyed by the current
// user plus the chosen partner, so there is no route to a conversation
// you are not part of. Markdown bodies are rendered + sanitized server
// side (see chat_markdown.go) before they reach either browser.
package chat

import (
	"angry-gopher/server/web"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// maxChatMessageBytes caps a single posted message. Generous — we want
// to encourage longer posts — but bounded.
const maxChatMessageBytes = 64 * 1024

// easternLoc formats message times in the same zone as the rest of the
// site; falls back to UTC if the zoneinfo isn't available.
var easternLoc = func() *time.Location {
	if loc, err := time.LoadLocation("America/New_York"); err == nil {
		return loc
	}
	return time.UTC
}()

func formatChatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.In(easternLoc).Format("Jan 2 · 3:04 PM")
}

// HandleChat serves /chat: a conversation when ?with=<partner> names a
// valid partner, otherwise a small people-picker.
func HandleChat(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat" {
		http.NotFound(w, r)
		return
	}
	if !web.IsMember(r) {
		next := "/chat"
		if r.URL.RawQuery != "" {
			next += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape(next), http.StatusSeeOther)
		return
	}
	user := web.CurrentUser(r)
	partner := strings.TrimSpace(r.URL.Query().Get("with")) // partner user id
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if !validChatPartner(user.ID, partner) {
		renderChatPicker(w, user)
		return
	}
	renderChatConversation(w, user, partner)
}

// ChatJSPath is the embedded chat client bundle (committed, hand-written;
// not build-generated). Served at /chat/chat.js.
var ChatJSPath = "chat/chat.js"

// HandleChatJS serves the chat client script from the embedded assets.
func HandleChatJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatJSPath, "chat.js missing from the binary")
}

// validChatPartner reports whether partner id is a usable conversation
// partner for user id: another member (chat is members-only), not
// yourself or empty.
func validChatPartner(userID, partnerID string) bool {
	return partnerID != "" && partnerID != userID && web.UserIsMember(partnerID)
}

// renderChatPicker lists the members you can message (everyone with a
// password), minus yourself — linked by id, shown by name.
func renderChatPicker(w http.ResponseWriter, user web.User) {
	chatPageHeader(w, "People", user, "people")
	fmt.Fprint(w, `<p class="muted">Pick a member to message:</p><ul>`)
	n := 0
	for _, m := range web.ListMembers() {
		if m.ID == user.ID {
			continue
		}
		fmt.Fprintf(w, `<li><a href="/chat?with=%s">%s</a></li>`,
			url.QueryEscape(m.ID), html.EscapeString(m.Name))
		n++
	}
	if n == 0 {
		fmt.Fprint(w, `<li class="muted">No other members yet.</li>`)
	}
	fmt.Fprint(w, `</ul>`)
	web.PageFooter(w)
}

func renderChatConversation(w http.ResponseWriter, user web.User, partnerID string) {
	msgs, err := ReadChatMessages(user.ID, partnerID)
	if err != nil {
		http.Error(w, "read conversation: "+err.Error(), http.StatusInternalServerError)
		return
	}
	partnerName := web.GetUserName(partnerID)

	chatPageHeader(w, "Chat with "+partnerName, user, "")
	fmt.Fprint(w, chatCSS)
	fmt.Fprintf(w, `<div id="chat-root" data-partner="%s">`, html.EscapeString(partnerID))
	fmt.Fprint(w, `<div class="chat-views" id="chat-views">`+
		`<span class="chat-view-tabs">`+
		`<a href="#" data-view="rendered" class="active">Rendered</a> · `+
		`<a href="#" data-view="transcript">Transcript</a></span>`+
		`</div>`)

	fmt.Fprint(w, `<div class="chat-layout"><div class="chat-main">`+
		`<div class="chat-navbar"><button type="button" id="chat-back" class="chat-back" title="Back to where you were before the last jump" disabled>&larr;</button></div>`+
		`<div class="chat-history view-rendered" id="chat-history"><div class="chat-bubbles" id="chat-bubbles">`)
	if len(msgs) == 0 {
		fmt.Fprint(w, `<p class="muted" id="chat-empty">No messages yet. Say hello 👋</p>`)
	}
	// The feed (bubbles + transcript) is built client-side from the SSE
	// replay; the server ships only this skeleton.
	fmt.Fprint(w, `</div><pre class="chat-transcript" id="chat-transcript"></pre></div></div>
<div class="chat-compose">
  <form id="chat-form">
    <textarea id="chat-body" placeholder="Write a message…  Markdown is supported, and longer posts are welcome."></textarea>
    <div class="chat-compose-actions">
      <button type="submit">Send</button>
      <button type="button" id="chat-image-btn">Image</button>
    </div>
  </form>
  <input type="file" id="chat-file" accept="image/png,image/jpeg,image/gif,image/webp" style="display:none">
  <div class="chat-status" id="chat-status"></div>
  <div class="chat-hint">Markdown supported · paste or attach an image · Ctrl/⌘-Enter to send</div>
</div></div>`)

	fmt.Fprintf(w, `</div><script src="/chat/chat.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion))

	web.PageFooter(w)
}

// HandleChatSend appends a posted message. Async (fetch) callers send
// X-Chat-Async and get 204; a plain form post gets a redirect back to
// the conversation (no-JS fallback).
func HandleChatSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !web.IsMember(r) {
		http.Error(w, "chat requires a member account", http.StatusForbidden)
		return
	}
	user := web.CurrentUser(r)

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

	partner := strings.TrimSpace(r.FormValue("with")) // partner user id
	body := strings.TrimSpace(r.FormValue("body"))
	async := r.Header.Get("X-Chat-Async") == "1"

	if !validChatPartner(user.ID, partner) {
		http.Error(w, "unknown conversation partner", http.StatusBadRequest)
		return
	}
	if body == "" {
		chatSendDone(w, r, partner, async)
		return
	}
	if _, err := AppendChatMessage(user, partner, body); err != nil {
		http.Error(w, "save message: "+err.Error(), http.StatusInternalServerError)
		return
	}
	web.TouchUser(user.ID) // sending a message counts as activity
	chatSendDone(w, r, partner, async)
}

func chatSendDone(w http.ResponseWriter, r *http.Request, partner string, async bool) {
	if async {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/chat?with="+url.QueryEscape(partner), http.StatusSeeOther)
}

// HandleChatStream is the SSE endpoint. It replays from `since` (or the
// Last-Event-ID on reconnect) and then streams live messages until the
// client disconnects.
func HandleChatStream(w http.ResponseWriter, r *http.Request) {
	if !web.IsMember(r) {
		http.Error(w, "chat requires a member account", http.StatusForbidden)
		return
	}
	user := web.CurrentUser(r)
	partner := strings.TrimSpace(r.URL.Query().Get("with")) // partner user id
	if !validChatPartner(user.ID, partner) {
		http.Error(w, "unknown conversation partner", http.StatusBadRequest)
		return
	}

	since := 0
	if lei := strings.TrimSpace(r.Header.Get("Last-Event-ID")); lei != "" {
		if n, err := strconv.Atoi(lei); err == nil {
			since = n + 1
		}
	} else if q := r.URL.Query().Get("since"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n >= 0 {
			since = n
		}
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	// This connection is long-lived; clear the server's 30s WriteTimeout
	// so it isn't torn down mid-stream.
	_ = rc.SetWriteDeadline(time.Time{})

	backlog, ch, cancel := OpenChatStream(user.ID, partner, since)
	defer cancel()

	for _, evt := range backlog {
		if writeChatEvent(w, rc, evt, user.Name) != nil {
			return
		}
	}
	if rc.Flush() != nil {
		return
	}

	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case evt, ok := <-ch:
			if !ok {
				return
			}
			if writeChatEvent(w, rc, evt, user.Name) != nil {
				return
			}
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		}
	}
}

// chatWireMsg is the JSON payload of one SSE message event.
type chatWireMsg struct {
	Index int    `json:"index"`
	From  string `json:"from"`
	Time  string `json:"time"`
	HTML  string `json:"html"`
	Enc   string `json:"enc"`
	Body  string `json:"body"` // raw markdown source, for client-side quote-reply
	Hash  string `json:"hash"`
	Mine  bool   `json:"mine"`
}

func writeChatEvent(w io.Writer, rc *http.ResponseController, evt chatEvent, me string) error {
	wire := chatWireMsg{
		Index: evt.Index,
		From:  evt.Msg.From,
		Time:  formatChatTime(evt.Msg.At),
		HTML:  string(RenderChatMarkdown(evt.Msg.Body)),
		Enc:   chatStoredForm(evt.Index, evt.Msg),
		Body:  evt.Msg.Body,
		Hash:  evt.Msg.Hash,
		Mine:  evt.Msg.From == me,
	}
	data, err := json.Marshal(wire)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "id: %d\ndata: %s\n\n", evt.Index, data); err != nil {
		return err
	}
	return rc.Flush()
}

const chatCSS = `<style>
/* The conversation page fills the viewport; only the message history
   scrolls. The title lives in the top bar, so there's no in-body heading.
   overflow stays visible — a flex mishap degrades to a page scrollbar,
   never clipped content. */
html, body { height:100%; }
.app-body-wrap { margin:10px auto; padding:0 24px 10px; min-height:0;
                 max-width:890px; display:flex; flex-direction:column; }
/* #chat-root wraps the views row + layout; it must carry the fill down the
   flex chain (without this it sizes to content, collapsing the compose box
   when the feed is empty). */
#chat-root { flex:1; min-height:0; display:flex; flex-direction:column; }
.chat-layout { display:flex; gap:20px; flex:1; min-height:0; }
.chat-main { min-width:0; flex:1; display:flex; flex-direction:column; min-height:0; }
.chat-navbar { margin-bottom:8px; }
.chat-back { font-size:14px; line-height:1; padding:3px 11px; background:#eee; color:#333;
             border:1px solid #ccc; border-radius:4px; cursor:pointer; }
.chat-back:hover:enabled { background:#e3e3e3; }
.chat-back:disabled { opacity:0.4; cursor:default; }
.chat-history { min-width:0; flex:1; min-height:0; overflow-y:auto;
                border:1px solid #ddd; border-radius:8px; padding:12px; background:#fcfcf8; }
.chat-compose form { margin:0; }
.chat-compose textarea { width:100%; min-height:200px; resize:vertical; box-sizing:border-box;
                         font-family:inherit; font-size:14px; padding:8px; }
.chat-compose button { margin-top:8px; }
.chat-msg { margin:0 0 12px; padding:8px 10px; border-radius:8px; max-width:88%; }
.chat-msg.mine { background:#e7e7ff; margin-left:auto; }
.chat-msg.theirs { background:#f0f0e6; margin-right:auto; }
/* Break long unbreakable runs (e.g. URLs) so they wrap inside the bubble
   instead of overflowing it — alignment-independent. */
.chat-body { overflow-wrap:anywhere; }
.chat-meta { font-size:11px; color:#888; margin-bottom:3px; }
.chat-meta .msg-quote { font-size:10px; color:#888; background:none; border:none;
                        padding:0 2px; cursor:pointer; text-decoration:underline; }
.chat-meta .msg-quote:hover { color:#000080; }
.chat-body a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:0.9em;
                       background:#eaeaff; color:#000080; padding:0 4px; border-radius:3px;
                       text-decoration:none; }
.chat-body a.msg-ref:hover { background:#d8d8ff; }
/* The selected message keeps a steady highlight ring (was a brief flash). */
.chat-msg.selected { box-shadow:0 0 0 2px #ffcf3a; }
.chat-body p:first-child { margin-top:0; }
.chat-body p:last-child { margin-bottom:0; }
.chat-body pre { background:#f4f4ec; padding:8px; border-radius:4px; overflow-x:auto; }
/* A ~~~ quote fence (quote-reply) renders verbatim but reads as a quote, not
   code: proportional font, left rule, soft tint, wrapping preserved. */
.chat-body pre.chat-quote { font-family:inherit; white-space:pre-wrap; overflow-wrap:anywhere;
                            background:#f6f6fb; border-left:3px solid #b9b9e0;
                            border-radius:0 4px 4px 0; margin:6px 0; padding:6px 10px;
                            color:#444; overflow-x:visible; }
.chat-transcript { display:none; margin:0; white-space:pre-wrap; overflow-wrap:anywhere;
                   font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; color:#333; }
.chat-history.view-transcript #chat-bubbles { display:none; }
.chat-history.view-transcript .chat-transcript { display:block; }
.chat-views { margin:0 0 8px; font-size:13px; display:flex; align-items:center; gap:12px; }
.chat-views a { text-decoration:none; }
.chat-views a.active { font-weight:bold; color:#000; cursor:default; }
.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }
.chat-compose-actions button { margin-top:0; }
.chat-body img { max-width:100%; max-height:320px; display:block; margin:6px 0;
                 border-radius:6px; cursor:zoom-in; }
.chat-img-dialog { border:1px solid #000080; border-radius:10px; padding:10px;
                   display:flex; flex-direction:column; gap:8px; }
.chat-img-dialog::backdrop { background:rgba(0,0,0,0.55); }
.chat-img-controls { display:flex; align-items:center; gap:10px; }
.chat-img-controls input[type=range] { flex:1; }
/* Fixed viewport: never resizes, so the slider stays put. The image is
   scaled in px inside it and overflows into scrollbars when zoomed in. */
.chat-img-scroll { width:70vw; height:70vh; overflow:auto; background:#faf9f5; border-radius:6px; }
.chat-img-scroll img { display:block; }
.chat-hint { font-size:12px; color:#999; margin-top:8px; }
.chat-status { font-size:12px; color:#b00020; min-height:16px; margin-top:6px; }
/* Wide (landscape): side by side — conversation left, compose on the RIGHT.
   The compose column is full height; its textarea flexes so Send/Image stay
   pinned and visible. */
@media (orientation: landscape) {
  .chat-layout { flex-direction:row; align-items:stretch; }
  .chat-main { flex:1; }
  .chat-compose { width:320px; flex:none; display:flex; flex-direction:column; min-height:0; }
  .chat-compose form { display:flex; flex-direction:column; flex:1; min-height:0; }
  .chat-compose textarea { flex:1; min-height:0; }
}
/* Tall (portrait): single column — history fills, compose sits at the
   BOTTOM at a fixed height (both stay on screen). */
@media (orientation: portrait) {
  .chat-layout { flex-direction:column; align-items:stretch; }
  .chat-compose { width:auto; flex:none; }
  .chat-compose textarea { min-height:120px; }
}
</style>`
