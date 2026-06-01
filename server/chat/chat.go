// Chat surface: a private one-on-one conversation page + a send
// endpoint. The live-delivery SSE for one open session lives in
// chat_stream.go (the other two SSE streams, notify and recent, are in
// chat_notify.go and recent.go respectively).
//
// Privacy is structural: a conversation is always keyed by the current
// user plus the chosen partner, so there is no route to a conversation
// you are not part of. Markdown bodies are rendered + sanitized server
// side (see chat_markdown.go) before they reach either browser.
package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"encoding/json"
	"errors"
	"fmt"
	"html"
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

// URL space (mirrors the on-disk layout under {ChatDataRoot}/<conv>/sessions/):
//
//	/chat                                   picker; or one-partner shortcut
//	                                        to /chat/default
//	/chat/default                           303 to the user's last (conv, sid)
//	/chat/conversations                     JSON: the whole (partner × time)
//	                                        matrix for the key-holder (API
//	                                        discovery; browsers use the pages)
//	/chat/c/<conv>                          303 to /chat/c/<conv>/<default-sid>
//	/chat/c/<conv>/<sid>                    conversation page (one session)
//	/chat/c/<conv>/<sid>/stream             SSE
//	/chat/c/<conv>/<sid>/send               POST a message
//	/chat/c/<conv>/<sid>/upload             POST an image
//	/chat/c/<conv>/<sid>/uploads/<file>     serve an uploaded image
//
// Conv keys are always "<a>_<b>" with the smaller numeric id first
// (chatPairKey); the path-only URL space means the server enforces
// participant access (ChatKeyParticipant) rather than trusting the
// caller's chosen partner id.

// HandleChat serves /chat itself: either the people-picker, or a
// shortcut redirect when there's exactly one other principal to talk to
// (the common case today). Conversations live under /chat/c/...
func HandleChat(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat" {
		http.NotFound(w, r)
		return
	}
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape("/chat"), http.StatusSeeOther)
		return
	}
	user := users.CurrentUser(r)
	// One-partner shortcut: skip the picker, drop into that conv (which
	// itself redirects to the default session).
	if only, ok := onlyOtherPartner(user.ID); ok {
		http.Redirect(w, r, "/chat/c/"+chatPairKey(user.ID, only), http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	renderChatPicker(w, user)
}

// chatPathParticipant resolves and authorizes the {conv} path
// parameter against the current request. ok=false means an HTTP
// response has already been written (login redirect, 404, etc); the
// caller should just return.
func chatPathParticipant(w http.ResponseWriter, r *http.Request) (user users.User, conv string, ok bool) {
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape(r.URL.Path), http.StatusSeeOther)
		return
	}
	user = users.CurrentUser(r)
	conv = r.PathValue("conv")
	if !ChatKeyParticipant(conv, user.ID) {
		http.NotFound(w, r) // don't reveal whether the conv exists
		return
	}
	ok = true
	return
}

// chatPathSession is chatPathParticipant plus validation of the {sid} path
// param: a malformed session id 404s exactly like a non-participant conv. It
// keeps "being in a session" safe for ANY id — sid flows straight into a
// sessions/<sid> filesystem path, and a topic name is user-supplied — so
// every sid-bearing handler funnels through this one gate.
func chatPathSession(w http.ResponseWriter, r *http.Request) (user users.User, conv, sid string, ok bool) {
	user, conv, ok = chatPathParticipant(w, r)
	if !ok {
		return
	}
	sid = r.PathValue("sid")
	if !validSessionID(sid) {
		http.NotFound(w, r) // don't reveal whether the session exists
		ok = false
		return
	}
	return
}

// HandleChatConv serves /chat/c/<conv>: redirects to the right session
// for this user (their last-viewed, falling back to newest, falling
// back to today).
func HandleChatConv(w http.ResponseWriter, r *http.Request) {
	user, conv, ok := chatPathParticipant(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)
	sid := resolveSessionForUser(user.ID, partner)
	http.Redirect(w, r, "/chat/c/"+conv+"/"+url.PathEscape(sid), http.StatusSeeOther)
}

// highestGeneralSession returns the general<N> session with the largest N in
// the conversation (the "most recent general stream"), or "" if there is
// none. Computed on the fly from the session list — no stored pointer, just
// the equivalent of `ls general*` picking the highest number.
func highestGeneralSession(a, b string) string {
	best, bestN := "", -1
	for _, sid := range ListChatSessions(a, b) {
		if !strings.HasPrefix(sid, "general") {
			continue
		}
		if n, err := strconv.Atoi(sid[len("general"):]); err == nil && n > bestN {
			bestN, best = n, sid
		}
	}
	return best
}

// HandleChatNewTopic creates a topic — a session with a custom name — in the
// conversation named in the path (/chat/c/<conv>/new), and seeds it with a
// "hi" from the creator so it exists on disk and shows up immediately. A
// topic is just a session, so once created it behaves exactly like a date
// one. Any participant of the conv may create one (existence under the conv
// dir IS the participation grant). Returns {conv, sid} so the client can
// switch straight to it.
func HandleChatNewTopic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, conv, ok := chatPathParticipant(w, r)
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
	partner, ok := OtherInConv(user.ID, conv)
	if !ok {
		http.Error(w, "bad conversation", http.StatusBadRequest)
		return
	}
	if ChatSessionExists(user.ID, partner, topic) {
		http.Error(w, "That topic already exists.", http.StatusConflict)
		return
	}
	if _, err := AppendChatMessage(user, partner, topic, "hi", ""); err != nil {
		http.Error(w, "create topic: "+err.Error(), http.StatusInternalServerError)
		return
	}
	SetUserLastSession(user.ID, user.ID, partner, topic)
	users.TouchUser(user.ID)
	// Announce the new topic in the most recent general stream (highest
	// general<N>, computed on the fly), so the partner sees it where they
	// already watch — and gets the notification ping there. Best-effort; skip
	// if there's no general stream, or the new topic itself is the one.
	if gen := highestGeneralSession(user.ID, partner); gen != "" && gen != topic {
		_, _ = AppendChatMessage(user, partner, gen,
			"New topic: ["+topic+"](/chat/c/"+conv+"/"+topic+")", "")
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"conv": conv, "sid": topic})
}

// HandleChatPin toggles whether a session is in the caller's Pinned group for
// this conversation. Two routes hang off the session like send/stream do:
// POST /chat/c/<conv>/<sid>/pin and .../unpin. Per-user state; conv-level auth
// (any participant pins their own view); the sid is validated by chatPathSession.
func HandleChatPin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, conv, sid, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	SetSessionPinned(user.ID, conv, sid, !strings.HasSuffix(r.URL.Path, "/unpin"))
	w.WriteHeader(http.StatusNoContent)
}

// HandleChatPage serves /chat/c/<conv>/<sid>: renders one session.
func HandleChatPage(w http.ResponseWriter, r *http.Request) {
	user, conv, sid, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)
	SetUserLastSession(user.ID, user.ID, partner, sid)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	renderChatConversation(w, user, partner, conv, sid)
}

// resolveSessionForUser picks the session a user lands on when only
// the conv is named (no explicit sid in the URL). Order: user's
// last-viewed -> conv's newest -> today's date (so a brand-new conv
// auto-creates today's session on first post).
func resolveSessionForUser(uid, partner string) string {
	if last := LastUserSession(uid, uid, partner); last != "" && ChatSessionExists(uid, partner, last) {
		return last
	}
	if def := DefaultChatSession(uid, partner); def != "" {
		return def
	}
	return time.Now().UTC().Format("2006-01-02")
}

// HandleChatDefault redirects to the user's most-recently-viewed
// (conv, session). Falls back to /chat (the picker / one-partner
// shortcut) if the user has never been to any conv.
func HandleChatDefault(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape("/chat/default"), http.StatusSeeOther)
		return
	}
	user := users.CurrentUser(r)
	conv := LastUserConv(user.ID)
	if conv == "" || !ChatKeyParticipant(conv, user.ID) {
		http.Redirect(w, r, "/chat", http.StatusSeeOther)
		return
	}
	partner, _ := OtherInConv(user.ID, conv)
	sid := resolveSessionForUser(user.ID, partner)
	http.Redirect(w, r, "/chat/c/"+conv+"/"+url.PathEscape(sid), http.StatusSeeOther)
}

// HandleChatConversations serves GET /chat/conversations: a JSON view of
// the whole (partner × time) matrix for the authenticated principal —
// every other authorized principal they can talk to, each with that
// conversation's sessions (newest-first) and the session a bare
// /chat/c/<conv> would land on. This is the discovery entry point for
// API-key clients (browsers navigate the HTML pages instead); it's a
// passive read with no side effects. The matrix is small (a few convs ×
// a few sessions), so one call returns the lot — a client reads it once,
// picks a (conv, sid), then uses the uniform /stream and /send endpoints.
func HandleChatConversations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	me := users.CurrentUser(r)

	type convPartner struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	type convEntry struct {
		Conv     string      `json:"conv"`
		Partner  convPartner `json:"partner"`
		Default  string      `json:"default"`
		Sessions []string    `json:"sessions"`
	}
	out := struct {
		Me            string      `json:"me"`
		Conversations []convEntry `json:"conversations"`
	}{Me: me.ID, Conversations: []convEntry{}}

	for _, partner := range users.ListAuthorized() {
		if partner.ID == me.ID {
			continue
		}
		sessions := ListChatSessions(me.ID, partner.ID)
		if sessions == nil {
			sessions = []string{} // encode as [] not null
		}
		out.Conversations = append(out.Conversations, convEntry{
			Conv:     chatPairKey(me.ID, partner.ID),
			Partner:  convPartner{ID: partner.ID, Name: partner.Name},
			Default:  resolveSessionForUser(me.ID, partner.ID),
			Sessions: sessions,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// onlyOtherPartner returns the partner id when there is exactly one
// other authorized principal (member or agent) you could talk to, plus
// ok=true. Otherwise (zero or two+), ok is false and the caller falls
// back to the picker.
func onlyOtherPartner(uid string) (string, bool) {
	var only string
	for _, m := range users.ListAuthorized() {
		if m.ID == uid {
			continue
		}
		if only != "" {
			return "", false // two+ others — picker is meaningful
		}
		only = m.ID
	}
	if only == "" {
		return "", false
	}
	return only, true
}

// ChatJSPath is the embedded chat client bundle (committed, hand-written;
// not build-generated). Served at /chat/chat.js.
var ChatJSPath = "chat/chat.js"

// HandleChatJS serves the chat client script from the embedded assets.
func HandleChatJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatJSPath, "chat.js missing from the binary")
}

// ChatSearchJSPath is the embedded search-modal client (committed,
// hand-written). Loaded as a sibling of chat.js on the conversation page.
var ChatSearchJSPath = "chat/chat_search.js"

// HandleChatSearchJS serves the search-modal script from the embedded assets.
func HandleChatSearchJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatSearchJSPath, "chat_search.js missing from the binary")
}

// ChatLeftSidebarJSPath is the embedded left-sidebar client (committed,
// hand-written). Drives add-topic + drag-to-pin behavior on the
// server-rendered sidebar markup.
var ChatLeftSidebarJSPath = "chat/chat_left_sidebar.js"

// HandleChatLeftSidebarJS serves the left-sidebar script from the embedded assets.
func HandleChatLeftSidebarJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatLeftSidebarJSPath, "chat_left_sidebar.js missing from the binary")
}

// ChatRightSidebarJSPath is the embedded right-sidebar client — slim
// shell that toggles between the open-compose and closed-panel states.
var ChatRightSidebarJSPath = "chat/chat_right_sidebar.js"

// HandleChatRightSidebarJS serves the right-sidebar script from the embedded assets.
func HandleChatRightSidebarJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatRightSidebarJSPath, "chat_right_sidebar.js missing from the binary")
}

// ChatComposeJSPath is the embedded compose client — form submit,
// send-state machine, image upload, alerts.
var ChatComposeJSPath = "chat/chat_compose.js"

// HandleChatComposeJS serves the compose script from the embedded assets.
func HandleChatComposeJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatComposeJSPath, "chat_compose.js missing from the binary")
}

// ChatHelpJSPath is the embedded global keyboard-dispatcher — the keys
// it handles are the same ones documented in the chat-keyhelp panel.
var ChatHelpJSPath = "chat/chat_help.js"

// HandleChatHelpJS serves the keyboard-dispatcher script from the embedded assets.
func HandleChatHelpJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatHelpJSPath, "chat_help.js missing from the binary")
}

// NotifyJSPath is the shared cross-page notify + tab-alert module, loaded
// on both the chat conversation page and the docs page.
var NotifyJSPath = "chat/notify.js"

// HandleNotifyJS serves the shared notify module from the embedded assets.
func HandleNotifyJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, NotifyJSPath, "notify.js missing from the binary")
}

// MessageJSPath is the per-bubble Message class — owns the bubble DOM,
// click routing, image/code popups, and in-place "Edit of MSG_*"
// supersession. Exposes Message.classifyBodyClick / showImagePopup /
// showCodePopup as module-level statics so search results can reuse them.
var MessageJSPath = "chat/message.js"

// HandleMessageJS serves the Message module from the embedded assets.
func HandleMessageJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, MessageJSPath, "message.js missing from the binary")
}

// MessageViewJSPath is the list-of-bubbles widget — owns selection state,
// scroll-driven re-selection, arrow/Home/End/PgUp/PgDn keys, backlog
// batch mode, and the image-decode stabilizer.
var MessageViewJSPath = "chat/message_view.js"

// HandleMessageViewJS serves the MessageView module from the embedded assets.
func HandleMessageViewJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, MessageViewJSPath, "message_view.js missing from the binary")
}

// NavStackJSPath is the back/forward state machine — middle_pane.js
// wires MessageView's setSelectedBubble (push), the back/forward
// buttons (back/forward), and the view.focusBubble walk into it.
var NavStackJSPath = "chat/nav_stack.js"

// HandleNavStackJS serves the NavStack module from the embedded assets.
func HandleNavStackJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, NavStackJSPath, "nav_stack.js missing from the binary")
}

// MiddlePaneJSPath wraps MessageView + NavStack + the back/fwd buttons
// behind a small API (append, focusBubble, getSelected, caughtUp, etc.)
// that chat.js drives. It's the bubble-feed widget — chat.js stays the
// workhorse for domain actions, message tracking, SSE, supersession,
// and sibling-module wiring.
var MiddlePaneJSPath = "chat/middle_pane.js"

// HandleMiddlePaneJS serves the middle-pane module from the embedded assets.
func HandleMiddlePaneJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, MiddlePaneJSPath, "middle_pane.js missing from the binary")
}

// ChatImagePopupJSPath is the shared image-zoom dialog — reused by chat
// bubbles (via Message), search results, and the Images transcript view.
var ChatImagePopupJSPath = "chat/chat_image_popup.js"

// HandleChatImagePopupJS serves the shared image-popup module.
func HandleChatImagePopupJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatImagePopupJSPath, "chat_image_popup.js missing from the binary")
}

// ChatCodePopupJSPath is the shared code-monospace dialog — reused by chat
// bubbles (via Message), search results, and the Code transcript view.
var ChatCodePopupJSPath = "chat/chat_code_popup.js"

// HandleChatCodePopupJS serves the shared code-popup module.
func HandleChatCodePopupJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatCodePopupJSPath, "chat_code_popup.js missing from the binary")
}

// validChatPartner reports whether partner id is a usable conversation
// partner for user id: another authorized principal (member or agent),
// not yourself or empty.
func validChatPartner(userID, partnerID string) bool {
	return partnerID != "" && partnerID != userID && users.UserIsAuthorized(partnerID)
}

// renderChatPicker lists the principals you can message (members + the
// Claude agent), minus yourself — linked by id, shown by name.
func renderChatPicker(w http.ResponseWriter, user users.User) {
	chatPageHeader(w, "Chat", user, "chat")
	fmt.Fprint(w, `<p class="muted">Pick someone to message:</p><ul>`)
	n := 0
	for _, m := range users.ListAuthorized() {
		if m.ID == user.ID {
			continue
		}
		fmt.Fprintf(w, `<li><a href="/chat/c/%s">%s</a></li>`,
			chatPairKey(user.ID, m.ID), html.EscapeString(m.Name))
		n++
	}
	if n == 0 {
		fmt.Fprint(w, `<li class="muted">No other members yet.</li>`)
	}
	fmt.Fprint(w, `</ul>`)
	web.PageFooter(w)
}

func renderChatConversation(w http.ResponseWriter, user users.User, partnerID, conv, sessionID string) {
	// Fail-fast on a corrupt session file before we ship the page shell —
	// the SSE backlog reads the same file but errors there are harder to
	// surface. The slice itself is discarded; the client builds the feed
	// from the SSE replay.
	if _, err := ReadChatSession(user.ID, partnerID, sessionID); err != nil {
		http.Error(w, "read conversation: "+err.Error(), http.StatusInternalServerError)
		return
	}
	partnerName := users.GetUserName(partnerID)

	chatPageHeader(w, "Chat w/"+partnerName+": "+sessionID, user, "")
	fmt.Fprint(w, chatCSS)
	// data-conv + data-session let chat.js build the API URLs
	// (/chat/c/<conv>/<sid>/{stream,send,upload}) without re-deriving
	// the pair key. data-partner stays for display labels (mine vs theirs).
	fmt.Fprintf(w, `<div id="chat-root" data-conv="%s" data-session="%s" data-partner="%s">`,
		html.EscapeString(conv), html.EscapeString(sessionID), html.EscapeString(partnerID))
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)

	fmt.Fprint(w, `<div class="chat-layout">`)
	renderChatSidebar(w, user, partnerID, conv, sessionID)
	// The middle column (wrapper + navbar with Back/Forward/🔍, history
	// surface, bubble list, all their styling) is built client-side by
	// chat/middle_pane.js — this is just the mount slot.
	fmt.Fprint(w, `<div id="chat-feed"></div>`)
	fmt.Fprint(w, `<div class="chat-compose" id="chat-right-sidebar">
  <div class="chat-closed-panel" id="chat-closed-panel">
    <button type="button" id="chat-open-compose" class="chat-open-compose">Open compose box</button>
  </div>
</div></div>`)

	// All sibling modules load BEFORE chat.js — chat.js's IIFE calls each
	// .init/use at the bottom, and the browser executes <script> tags in
	// document order for these non-module siblings. message.js and
	// message_view.js are foundational (used by chat.js's IIFE itself, not
	// just via init). notify.js loads after chat.js (no init dep).
	v := url.QueryEscape(web.AssetVersion)
	fmt.Fprintf(w, `</div><script src="/chat/chat_image_popup.js?v=%s"></script>`+
		`<script src="/chat/chat_code_popup.js?v=%s"></script>`+
		`<script src="/chat/message.js?v=%s"></script>`+
		`<script src="/chat/message_view.js?v=%s"></script>`+
		`<script src="/chat/nav_stack.js?v=%s"></script>`+
		`<script src="/chat/middle_pane.js?v=%s"></script>`+
		`<script src="/chat/chat_search.js?v=%s"></script>`+
		`<script src="/chat/chat_left_sidebar.js?v=%s"></script>`+
		`<script src="/chat/chat_right_sidebar.js?v=%s"></script>`+
		`<script src="/chat/chat_compose.js?v=%s"></script>`+
		`<script src="/chat/chat_help.js?v=%s"></script>`+
		`<script src="/chat/chat.js?v=%s"></script>`+
		`<script src="/chat/notify.js?v=%s"></script>`,
		v, v, v, v, v, v, v, v, v, v, v, v, v)

	web.PageFooter(w)
}

// renderChatSidebar emits the left-rail nav: the user's conversations
// (one row per other authorized principal) above the sessions of the
// current conv. Active conv + session are bolded. Server-rendered, no
// JS — picking a conv goes to /chat/c/<conv> which itself redirects to
// the user's default session for that pair.
func renderChatSidebar(w http.ResponseWriter, user users.User, partnerID, conv, sessionID string) {
	fmt.Fprint(w, `<aside class="chat-sidebar" id="chat-left-sidebar">`)

	// Conversations: every other authorized principal as a row.
	fmt.Fprint(w, `<div class="chat-sidebar-section"><div class="chat-sidebar-title">Conversations</div><ul class="chat-sidebar-list" data-section="conversations">`)
	for _, m := range users.ListAuthorized() {
		if m.ID == user.ID {
			continue
		}
		theirConv := chatPairKey(user.ID, m.ID)
		cls := ""
		if theirConv == conv {
			cls = ` class="active"`
		}
		fmt.Fprintf(w, `<li data-uid="%s"><a href="/chat/c/%s"%s>%s</a></li>`,
			html.EscapeString(m.ID), theirConv, cls, html.EscapeString(m.Name))
	}
	fmt.Fprint(w, `</ul></div>`)

	// Sessions of THIS conv, split into the user's Pinned group (above) and
	// the rest. Both alphabetical (ListChatSessions is sorted); pins are
	// per-user, and the two <ul>s are pointer drag/drop targets (chat.js).
	a, b := user.ID, partnerID
	sessions := ListChatSessions(a, b)
	pinned := PinnedSessions(user.ID, conv)
	item := func(sid string) {
		acls := ""
		if sid == sessionID {
			acls = ` class="active"`
		}
		fmt.Fprintf(w, `<li class="chat-session-item" data-sid="%s"><a href="/chat/c/%s/%s"%s draggable="false">%s</a></li>`,
			html.EscapeString(sid), conv, url.PathEscape(sid), acls, html.EscapeString(sid))
	}

	fmt.Fprint(w, `<div class="chat-sidebar-section"><div class="chat-sidebar-title">Pinned Sessions</div>`+
		`<ul class="chat-sidebar-list chat-session-drop" data-section="pinned">`)
	nPinned := 0
	for _, sid := range sessions {
		if pinned[sid] {
			item(sid)
			nPinned++
		}
	}
	if nPinned == 0 {
		fmt.Fprint(w, `<li class="muted chat-pin-hint">Drag a session here to pin it</li>`)
	}
	fmt.Fprint(w, `</ul></div>`)

	fmt.Fprint(w, `<div class="chat-sidebar-section"><div class="chat-sidebar-title">Sessions</div>`+
		`<ul class="chat-sidebar-list chat-session-drop" data-section="sessions">`)
	nUnpinned := 0
	for _, sid := range sessions {
		if !pinned[sid] {
			item(sid)
			nUnpinned++
		}
	}
	if nUnpinned == 0 {
		fmt.Fprint(w, `<li class="muted">No sessions yet</li>`)
	}
	fmt.Fprint(w, `</ul>`)
	// Add a topic = create a new session with a custom name in THIS conv.
	fmt.Fprint(w, `<form id="chat-add-topic" class="chat-add-topic">`+
		`<input type="text" id="chat-topic-name" placeholder="new-topic" autocomplete="off" maxlength="80" spellcheck="false">`+
		`<button type="submit">Add Topic</button>`+
		`<div class="chat-add-topic-err" id="chat-topic-err"></div></form>`)
	fmt.Fprint(w, `</div></aside>`)
}

// HandleChatSend appends a posted message to the session named in the
// path (/chat/c/<conv>/<sid>/send). Async (fetch) callers send
// X-Chat-Async and get 204; a plain form post gets a redirect back to
// the conversation page (no-JS fallback).
func HandleChatSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, conv, sessionID, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)

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
	cid := strings.TrimSpace(r.FormValue("cid")) // client-correlation id, echoed on the SSE broadcast
	async := r.Header.Get("X-Chat-Async") == "1"

	if markdown == "" {
		chatSendDone(w, r, conv, sessionID, async)
		return
	}
	if strings.HasPrefix(markdown, "DROP_ON_FLOOR") {
		// Test back door: accept the POST but neither save nor broadcast, so no
		// SSE echo returns and the sender's client exercises its timeout path.
		chatSendDone(w, r, conv, sessionID, async)
		return
	}
	if _, err := AppendChatMessage(user, partner, sessionID, markdown, cid); err != nil {
		http.Error(w, "save message: "+err.Error(), http.StatusInternalServerError)
		return
	}
	SetUserLastSession(user.ID, user.ID, partner, sessionID)
	users.TouchUser(user.ID) // sending a message counts as activity
	chatSendDone(w, r, conv, sessionID, async)
}

func chatSendDone(w http.ResponseWriter, r *http.Request, conv, sessionID string, async bool) {
	if async {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/chat/c/"+conv+"/"+url.PathEscape(sessionID), http.StatusSeeOther)
}

const chatCSS = `<style>
/* The conversation page fills the viewport; only the message history
   scrolls. The title lives in the top bar, so there's no in-body heading.
   overflow stays visible — a flex mishap degrades to a page scrollbar,
   never clipped content. */
html, body { height:100%; }
/* Chat overrides the platform's narrow text-page wrap — with the
   sidebar + main + compose, 890px squeezes the message feed. Let it
   fill the viewport; chat-msg's own max-width keeps bubbles from
   becoming ridiculously wide on ultrawide screens. */
.app-body-wrap { margin:10px auto; padding:0 24px 10px; min-height:0;
                 max-width:none; display:flex; flex-direction:column; }
/* #chat-root wraps the views row + layout; it must carry the fill down the
   flex chain (without this it sizes to content, collapsing the compose box
   when the feed is empty). */
#chat-root { flex:1; min-height:0; display:flex; flex-direction:column; }
.chat-layout { display:flex; gap:20px; flex:1; min-height:0; }
.chat-sidebar { width:180px; flex-shrink:0; overflow-y:auto; border-right:1px solid #ddd;
                padding-right:14px; font-size:13px; }
.chat-sidebar-section { margin-bottom:18px; }
.chat-sidebar-title { font-size:11px; text-transform:uppercase; letter-spacing:0.05em;
                       color:#888; margin-bottom:6px; font-weight:bold; }
.chat-sidebar-list { list-style:none; padding:0; margin:0; }
.chat-sidebar-list li { margin:0; }
.chat-sidebar-list li a { display:block; padding:4px 8px; border-radius:3px;
                           color:#000080; text-decoration:none; }
.chat-sidebar-list li a:hover { background:#f0f0ff; }
.chat-sidebar-list li a.active { background:#000080; color:white; font-weight:bold; }
.chat-sidebar-list li.muted { color:#888; padding:4px 8px; font-style:italic; }
.chat-session-item { touch-action:none; cursor:grab; user-select:none; -webkit-user-select:none; }
.chat-session-item.dragging { opacity:0.5; cursor:grabbing; }
.chat-session-drop { min-height:14px; border-radius:4px; }
.chat-session-drop.drop-active { outline:2px dashed #1a5fb4; outline-offset:-2px; background:#eef3fb; }
.chat-pin-hint { font-size:11px; }
.chat-drag-ghost { position:fixed; z-index:1000; pointer-events:none; background:#000080;
                   color:#fff; font-size:12px; padding:3px 9px; border-radius:4px;
                   box-shadow:0 2px 8px rgba(0,0,0,0.35); opacity:0.92; white-space:nowrap;
                   max-width:170px; overflow:hidden; text-overflow:ellipsis; }
.chat-add-topic { display:flex; flex-wrap:wrap; gap:4px; margin-top:8px; }
.chat-add-topic input { flex:1; min-width:0; padding:3px 6px; font-size:12px;
                        border:1px solid #ccc; border-radius:3px; font-family:inherit; }
.chat-add-topic button { padding:3px 8px; font-size:12px; flex:none; }
.chat-add-topic-err { flex-basis:100%; color:#b00020; font-size:11px; }
.chat-open-compose { font-size:13px; padding:4px 12px; background:#e7e7ff; color:#23235a;
                     border:1px solid #b9b9e0; border-radius:6px; cursor:pointer; }
.chat-open-compose:hover { background:#dcdcff; }
/* Keyboard cheatsheet shown in the freed compose space (closed state). The DOM
   itself is generated by chat_help.js from its KEYMAP — these styles paint
   what it builds. The key-buttons are real buttons (click triggers the same
   action as pressing the key); the kbd-look is just styling. Movement keys
   (arrows, Home/End, paging, Esc) aren't in the panel — discoverable. */
.chat-keyhelp { margin-top:18px; font-size:13px; color:#555; }
.chat-keyhelp-title { font-weight:bold; color:#333; margin-bottom:7px; }
.chat-key { margin:5px 0; }
.chat-keyhelp-key { display:inline-block; min-width:1.1em; text-align:center; padding:1px 6px;
                    font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; color:#333;
                    background:#fff; border:1px solid #ccc; border-bottom-width:2px; border-radius:4px;
                    margin-right:7px; cursor:pointer; }
.chat-keyhelp-key:hover { background:#f3f3ff; border-color:#9b9be0; }
.chat-keyhelp-key:active { background:#e7e7ff; border-bottom-width:1px; transform:translateY(1px); }
/* Middle column (wrapper, navbar with Back/Forward/🔍, history surface,
   bubble list, button styling) is owned by chat/middle_pane.js. */
/* Search modal: a two-phase palette — token autocomplete, then message
   results (the term highlighted in each message rendered like the feed).
   Pinned to a fixed top offset and grows downward as results fill in —
   never vertically re-centering. */
.chat-search-modal { position:fixed; top:56px; bottom:auto; left:0; right:0; margin:0 auto;
                     width:600px; max-width:92vw; max-height:calc(100vh - 80px); padding:0;
                     border:1px solid #b9b9e0; border-radius:10px; background:#fff;
                     display:flex; flex-direction:column; }
.chat-search-modal::backdrop { background:rgba(0,0,0,0.4); }
.chat-sr-input { margin:0; border:none; border-bottom:1px solid #e3e3ef; border-radius:10px 10px 0 0;
                 font-size:16px; padding:12px 16px; font-family:inherit; outline:none; }
.chat-sr-status { font-size:12px; color:#888; padding:6px 16px; border-bottom:1px solid #f0f0f4; flex:none; }
.chat-sr-list { overflow-y:auto; padding:4px 0; flex:1 1 auto; min-height:0; }
.chat-sr-row { padding:7px 16px; cursor:pointer; border-left:3px solid transparent; }
.chat-sr-row.sel { background:#eef0ff; border-left-color:#000080; }
.chat-sr-row:hover { background:#f6f6fb; }
.chat-sr-tok { font-weight:bold; color:#23235a; display:flex; align-items:baseline; gap:8px; }
.chat-sr-cnt { font-weight:normal; font-size:11px; color:#999; }
.chat-sr-rhead { font-size:11px; color:#888; margin-bottom:2px; }
.chat-sr-ctx { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; color:#555;
               white-space:pre-wrap; overflow-wrap:anywhere; margin-top:3px;
               max-height:4.6em; overflow:hidden; } /* phase 1: limited RAW context while typing */
.chat-sr-rbody { margin-top:3px; color:#333; font-size:13px; overflow-wrap:anywhere; } /* phase 2: full RENDERED message */
/* MSG_ refs are inert inside results (they'd jump the hidden feed, not the
   modal), so drop the link affordance. */
.chat-sr-rbody a.msg-ref { cursor:default; }
.chat-search-modal mark { background:#ffe680; color:inherit; border-radius:2px; padding:0; }
.chat-compose form { margin:0; }
.chat-compose textarea { width:100%; min-height:200px; resize:vertical; box-sizing:border-box;
                         font-family:inherit; font-size:14px; padding:8px; }
.chat-compose button { margin-top:8px; }
/* Bubble DOM + body-content classes (chat-msg, chat-meta, chat-body,
   chat-edited-* family, plus msg-ref / pre.chat-quote that goldmark +
   chat_msgref emit) are styled by chat/message.js itself. Nothing for
   this page to emit. */
.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }
.chat-compose-actions button { margin-top:0; }
/* The image + code popups own their own styles inside chat_image_popup.js
   and chat_code_popup.js respectively — no CSS coordination needed. */
/* Plain message-box modal (e.g. the "host may be down" notice). */
.chat-alert-dialog { max-width:90vw; border:1px solid #bbb; border-radius:8px; padding:18px 20px; }
.chat-alert-dialog::backdrop { background:rgba(0,0,0,0.4); }
.chat-alert-dialog p { margin:0 0 14px; }
.chat-alert-dialog button { padding:5px 16px; }
.chat-hint { font-size:12px; color:#999; margin-top:8px; }
.chat-status { font-size:12px; color:#b00020; min-height:16px; margin-top:6px; }
/* Wide (landscape): side by side — conversation left, compose on the RIGHT.
   The compose column is full height; its textarea flexes so Send/Image stay
   pinned and visible. */
@media (orientation: landscape) {
  .chat-layout { flex-direction:row; align-items:stretch; }
  .chat-compose { width:320px; flex:none; display:flex; flex-direction:column; min-height:0; }
  .chat-compose-body { display:flex; flex-direction:column; flex:1; min-height:0; }
  .chat-compose form { display:flex; flex-direction:column; flex:1; min-height:0; }
  .chat-compose textarea { flex:1; min-height:0; }
}
/* Tall (portrait): single column — history fills, compose sits at the
   BOTTOM at a fixed height (both stay on screen). The sidebar would
   eat too much vertical space stacked on top; hide it (use the picker
   or back-out to /chat to switch convs on portrait). */
@media (orientation: portrait) {
  .chat-layout { flex-direction:column; align-items:stretch; }
  .chat-sidebar { display:none; }
  .chat-compose { width:auto; flex:none; }
  .chat-compose textarea { min-height:120px; }
}
</style>`
