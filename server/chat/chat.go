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
	"angry-gopher/server/platform"
	"bytes"
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

// chatPathParticipant resolves the {conv} path parameter and confirms
// the caller participates in it. ok=false means an HTTP response has
// already been written (404 for non-participants); the caller returns.
// Caller's NEED_PASSWORD route gate already established the principal.
func chatPathParticipant(w http.ResponseWriter, r *http.Request) (user users.User, conv string, ok bool) {
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
	renderConversation(w, user, DMConv(user.ID, partner), sid)
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
	platform.ServeJS(w, ChatJSPath, "chat.js missing from the binary")
}

// ChatSearchJSPath is the embedded search-modal client (committed,
// hand-written). Loaded as a sibling of chat.js on the conversation page.
var ChatSearchJSPath = "chat/chat_search.js"

// HandleChatSearchJS serves the search-modal script from the embedded assets.
func HandleChatSearchJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatSearchJSPath, "chat_search.js missing from the binary")
}

// ChatLeftSidebarJSPath is the embedded left-sidebar client — builds
// the conversation/sessions rail from inline JSON, mounts the Add
// Topic form, and subscribes to /chat/sidebar/stream for upserts.
var ChatLeftSidebarJSPath = "chat/chat_left_sidebar.js"

// HandleChatLeftSidebarJS serves the left-sidebar script from the embedded assets.
func HandleChatLeftSidebarJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatLeftSidebarJSPath, "chat_left_sidebar.js missing from the binary")
}

// ChatAddTopicJSPath is the embedded Add-Topic form widget — the
// little form at the bottom of the left rail (input + button + error
// line + submit + redirect on success).
var ChatAddTopicJSPath = "chat/chat_add_topic.js"

// HandleChatAddTopicJS serves the add-topic widget from the embedded assets.
func HandleChatAddTopicJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatAddTopicJSPath, "chat_add_topic.js missing from the binary")
}

// ChatDragToPinJSPath is the embedded drag-to-pin gesture widget —
// pointer state machine for moving a session row between the Pinned
// and Sessions lists, including the optimistic-update + revert dance
// around the pin/unpin POST.
var ChatDragToPinJSPath = "chat/chat_drag_to_pin.js"

// HandleChatDragToPinJS serves the drag-to-pin widget from the embedded assets.
func HandleChatDragToPinJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatDragToPinJSPath, "chat_drag_to_pin.js missing from the binary")
}

// ChatRightSidebarJSPath is the embedded right-sidebar client — slim
// shell that toggles between the open-compose and closed-panel states.
var ChatRightSidebarJSPath = "chat/chat_right_sidebar.js"

// HandleChatRightSidebarJS serves the right-sidebar script from the embedded assets.
func HandleChatRightSidebarJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatRightSidebarJSPath, "chat_right_sidebar.js missing from the binary")
}

// ChatComposeJSPath is the embedded compose client — form submit,
// send-state machine, image upload, alerts.
var ChatComposeJSPath = "chat/chat_compose.js"

// HandleChatComposeJS serves the compose script from the embedded assets.
func HandleChatComposeJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatComposeJSPath, "chat_compose.js missing from the binary")
}

// ChatHelpJSPath is the embedded global keyboard-dispatcher — the keys
// it handles are the same ones documented in the chat-keyhelp panel.
var ChatHelpJSPath = "chat/chat_help.js"

// HandleChatHelpJS serves the keyboard-dispatcher script from the embedded assets.
func HandleChatHelpJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatHelpJSPath, "chat_help.js missing from the binary")
}

// NotifyJSPath is the shared cross-page notify + tab-alert module, loaded
// on both the chat conversation page and the docs page.
var NotifyJSPath = "chat/notify.js"

// HandleNotifyJS serves the shared notify module from the embedded assets.
func HandleNotifyJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, NotifyJSPath, "notify.js missing from the binary")
}

// MessageJSPath is the per-bubble Message class — owns the bubble DOM,
// click routing, image/code popups, and in-place "Edit of MSG_*"
// supersession. Exposes Message.classifyBodyClick / showImagePopup /
// showCodePopup as module-level statics so search results can reuse them.
var MessageJSPath = "chat/message.js"

// HandleMessageJS serves the Message module from the embedded assets.
func HandleMessageJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, MessageJSPath, "message.js missing from the binary")
}

// MessageViewJSPath is the list-of-bubbles widget — owns selection state,
// scroll-driven re-selection, arrow/Home/End/PgUp/PgDn keys, backlog
// batch mode, and the image-decode stabilizer.
var MessageViewJSPath = "chat/message_view.js"

// HandleMessageViewJS serves the MessageView module from the embedded assets.
func HandleMessageViewJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, MessageViewJSPath, "message_view.js missing from the binary")
}

// NavStackJSPath is the back/forward state machine — middle_pane.js
// wires MessageView's setSelectedBubble (push), the back/forward
// buttons (back/forward), and the view.focusBubble walk into it.
var NavStackJSPath = "chat/nav_stack.js"

// HandleNavStackJS serves the NavStack module from the embedded assets.
func HandleNavStackJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, NavStackJSPath, "nav_stack.js missing from the binary")
}

// MiddlePaneJSPath wraps MessageView + NavStack + the back/fwd buttons
// behind a small API (append, focusBubble, getSelected, caughtUp, etc.)
// that chat.js drives. It's the bubble-feed widget — chat.js stays the
// workhorse for domain actions, message tracking, SSE, supersession,
// and sibling-module wiring.
var MiddlePaneJSPath = "chat/middle_pane.js"

// HandleMiddlePaneJS serves the middle-pane module from the embedded assets.
func HandleMiddlePaneJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, MiddlePaneJSPath, "middle_pane.js missing from the binary")
}

// ChatImagePopupJSPath is the shared image-zoom dialog — reused by chat
// bubbles (via Message), search results, and the Images transcript view.
var ChatImagePopupJSPath = "chat/chat_image_popup.js"

// HandleChatImagePopupJS serves the shared image-popup module.
func HandleChatImagePopupJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatImagePopupJSPath, "chat_image_popup.js missing from the binary")
}

// ChatCodePopupJSPath is the shared code-monospace dialog — reused by chat
// bubbles (via Message), search results, and the Code transcript view.
var ChatCodePopupJSPath = "chat/chat_code_popup.js"

// HandleChatCodePopupJS serves the shared code-popup module.
func HandleChatCodePopupJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, ChatCodePopupJSPath, "chat_code_popup.js missing from the binary")
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
	platform.PageFooter(w)
}

// renderConversation renders one topic feed page — same shell for DMs
// and channels. The Conv supplies the URL space (conv-base attr lets
// chat.js build /send, /stream, /upload, and cross-session refs
// without branching on kind) and the storage shape (ReadSession + the
// sidebar payload).
func renderConversation(w http.ResponseWriter, user users.User, c Conv, sid string) {
	// Fail-fast on a corrupt session file before we ship the page shell.
	if _, err := c.ReadSession(sid); err != nil {
		http.Error(w, "read conversation: "+err.Error(), http.StatusInternalServerError)
		return
	}
	chatPageHeader(w, c.tabTitleFor(user.ID, sid), user, "")
	fmt.Fprint(w, chatCSS)
	fmt.Fprintf(w, `<div id="chat-root" data-conv="%s" data-conv-base="%s" data-session="%s">`,
		html.EscapeString(c.Key), html.EscapeString(c.baseURL()), html.EscapeString(sid))
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)

	fmt.Fprint(w, `<div class="chat-layout">`)
	emitChatSidebarMount(w, user, c, sid)
	// The middle column (wrapper + navbar with Back/Forward/🔍, history
	// surface, bubble list, all their styling) is built client-side by
	// chat/middle_pane.js — this is just the mount slot.
	fmt.Fprint(w, `<div id="chat-feed"></div>`)
	// Right sidebar (wrapper, closed-panel, "Open compose box" button,
	// the open-state compose form, and the keyhelp inside the closed-panel)
	// is built client-side by chat_right_sidebar.js + chat_compose.js +
	// chat_help.js — this is just the mount slot.
	fmt.Fprint(w, `<div id="chat-right-sidebar"></div></div>`)

	// All sibling modules load BEFORE chat.js — chat.js's IIFE calls each
	// .init/use at the bottom, and the browser executes <script> tags in
	// document order for these non-module siblings. message.js and
	// message_view.js are foundational (used by chat.js's IIFE itself, not
	// just via init). notify.js loads after chat.js (no init dep).
	v := url.QueryEscape(platform.AssetVersion)
	fmt.Fprintf(w, `</div><script src="/chat/chat_image_popup.js?v=%s"></script>`+
		`<script src="/chat/chat_code_popup.js?v=%s"></script>`+
		`<script src="/chat/message.js?v=%s"></script>`+
		`<script src="/chat/message_view.js?v=%s"></script>`+
		`<script src="/chat/nav_stack.js?v=%s"></script>`+
		`<script src="/chat/middle_pane.js?v=%s"></script>`+
		`<script src="/chat/chat_search.js?v=%s"></script>`+
		`<script src="/chat/chat_drag_to_pin.js?v=%s"></script>`+
		`<script src="/chat/chat_add_topic.js?v=%s"></script>`+
		`<script src="/chat/chat_left_sidebar.js?v=%s"></script>`+
		`<script src="/chat/chat_right_sidebar.js?v=%s"></script>`+
		`<script src="/chat/chat_compose.js?v=%s"></script>`+
		`<script src="/chat/chat_help.js?v=%s"></script>`+
		`<script src="/chat/chat.js?v=%s"></script>`+
		`<script src="/chat/notify.js?v=%s"></script>`,
		v, v, v, v, v, v, v, v, v, v, v, v, v, v, v)

	platform.PageFooter(w)
}

// sidebarItem is one labelled link in the left rail — used for partner
// conversations AND for sessions. `id` is the data-* attribute key the
// client uses for SSE dedupe (partners) and drag-to-pin (sessions).
// Online is the presence flag — meaningful for partner rows (does the
// partner have recent server activity?); always false for session rows.
type sidebarItem struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	URL    string `json:"url"`
	Active bool   `json:"active"`
	Online bool   `json:"online,omitempty"`
}

// sidebarPayload is what the server emits and the client renders the
// left rail from. Data shape mirrors the UI: three sections, no flags
// (pinned-ness is "which array you're in", not a bool on the item).
// Empty-state strings ("Drag a session here…", "No sessions yet") are
// the client's concern.
type sidebarPayload struct {
	Conversations  []sidebarItem `json:"conversations"`
	PinnedSessions []sidebarItem `json:"pinned_sessions"`
	Sessions       []sidebarItem `json:"sessions"`
}

// buildSidebarPayload computes the left-rail data for one conversation
// page render. Conversations row = every DM partner + every channel
// the viewer subscribes to (Zulip-shape: General sits beside Apoorva).
// Sessions / PinnedSessions are the current conv's topics, split by
// pinned state.
func buildSidebarPayload(user users.User, current Conv, sessionID string) sidebarPayload {
	var p sidebarPayload
	for _, m := range users.ListAuthorized() {
		if m.ID == user.ID {
			continue
		}
		theirConv := chatPairKey(user.ID, m.ID)
		p.Conversations = append(p.Conversations, sidebarItem{
			ID:     "uid:" + m.ID,
			Label:  m.Name,
			URL:    "/chat/c/" + theirConv,
			Active: current.Kind == KindDM && theirConv == current.Key,
			Online: IsOnline(m.ID),
		})
	}
	for _, name := range ListUserChannels(user.ID) {
		p.Conversations = append(p.Conversations, sidebarItem{
			ID:     "ch:" + name,
			Label:  "# " + name,
			URL:    "/channel/" + name,
			Active: current.Kind == KindChannel && name == current.Key,
		})
	}
	pinned := PinnedSessions(user.ID, current.Key)
	for _, sid := range current.ListSessions() {
		item := sidebarItem{
			ID:     sid,
			Label:  sid,
			URL:    current.topicURL(sid),
			Active: sid == sessionID,
		}
		if pinned[sid] {
			p.PinnedSessions = append(p.PinnedSessions, item)
		} else {
			p.Sessions = append(p.Sessions, item)
		}
	}
	return p
}

// emitChatSidebarMount writes a mount slot for chat_left_sidebar.js plus
// the initial payload as inline JSON. The JSON is shipped in a
// <script type="application/json"> sibling so first paint doesn't need
// a round-trip and the wire shape is what the SSE upserts would extend.
func emitChatSidebarMount(w http.ResponseWriter, user users.User, current Conv, sessionID string) {
	payload, err := json.Marshal(buildSidebarPayload(user, current, sessionID))
	if err != nil {
		// PRODUCT_DECISION: empty payload is a recoverable rendering result —
		// client builds empty sections, SSE backfills.
		payload = []byte(`{}`)
	}
	// PRODUCT_DECISION: escape `</` as `<\/` so a username (or future field
	// value) can't accidentally close the <script> tag. JSON spec allows
	// `\/` as an alternate encoding of `/`, so the client parser still sees
	// the same string.
	safe := bytes.ReplaceAll(payload, []byte("</"), []byte(`<\/`))
	fmt.Fprint(w, `<div id="chat-left-sidebar"></div>`)
	fmt.Fprintf(w, `<script type="application/json" id="chat-sidebar-data">%s</script>`, safe)
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

// PRODUCT_DECISION: only the page-shell layout lives here — the rules
// that span the whole flex chain from <html> down to .chat-layout. Every
// per-widget rule (left rail, middle column, right rail wrapper, compose
// form/textarea, help keyhelp, search modal, bubble DOM, popups) lives
// in the widget's own JS file. lynrummy.com is desktop-only; there are
// no orientation @media queries — the page assumes a landscape viewport.
const chatCSS = `<style>
/* The conversation page fills the viewport; only the message history
   scrolls. overflow stays visible — a flex mishap degrades to a page
   scrollbar, never clipped content. */
html, body { height:100%; }
/* Chat overrides the platform's narrow text-page wrap — with the
   sidebar + main + compose, 890px squeezes the message feed. */
.app-body-wrap { margin:10px auto; padding:0 24px 10px; min-height:0;
                 max-width:none; display:flex; flex-direction:column; }
#chat-root { flex:1; min-height:0; display:flex; flex-direction:column; }
.chat-layout { display:flex; flex-direction:row; align-items:stretch;
               gap:20px; flex:1; min-height:0; }
</style>`
