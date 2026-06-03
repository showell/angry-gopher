// /chat/recent: a flat reverse-chronological feed of activity across the
// signed-in user's chat sessions and personal docs. Initial-load source
// is file mtime (the server walks the convs the user participates in
// plus their docs dir on every GET). After load, a per-user SSE stream
// (/chat/recent/stream) delivers one event per write, and a 20-second
// client-side timer re-humanizes the When column without a round-trip.
package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type recentKind int

const (
	recentChat recentKind = iota
	recentDoc
)

type recentItem struct {
	kind recentKind
	at   time.Time
	// chat-only
	partner    string
	conv       string
	sid        string
	lastAuthor string // display name of the most recent sender, or ""
	// doc-only
	slug  string
	title string
}

// HandleRecent serves /chat/recent: the chrome + the activity list. Member
// (or agent) gate via the same redirect pattern as /chat itself.
func HandleRecent(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat/recent" {
		http.NotFound(w, r)
		return
	}
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape("/chat/recent"), http.StatusSeeOther)
		return
	}
	user := users.CurrentUser(r)
	items := gatherRecentItems(user)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	chatPageHeader(w, "Recent", user, "recent")
	// Cross-page user-attention strip + favicon-violet on incoming chat
	// pings (notify.js no-ops when this div is absent). Recent users tend
	// to camp here waiting for activity, so the tab needs to alert too.
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)
	fmt.Fprint(w, `<div id="recent-mount"></div>`)
	emitRecentData(w, items)
	fmt.Fprintf(w, `<script src="/chat/recent.js?v=%s"></script>`+
		`<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion))
	web.PageFooter(w)
}

// emitRecentData ships the initial activity feed as inline JSON next to
// the mount slot. The shape matches recentEvent, so the client uses ONE
// builder for both the first-paint rows and the live SSE upserts.
func emitRecentData(w http.ResponseWriter, items []recentItem) {
	payload := make([]recentEvent, 0, len(items))
	for _, it := range items {
		evt := recentEvent{At: it.at}
		switch it.kind {
		case recentChat:
			evt.Kind = "chat"
			evt.Conv = it.conv
			evt.SID = it.sid
			evt.Partner = it.partner
			evt.LastAuthor = it.lastAuthor
		case recentDoc:
			evt.Kind = "doc"
			evt.Slug = it.slug
			evt.Title = it.title
		}
		payload = append(payload, evt)
	}
	blob, err := json.Marshal(payload)
	if err != nil {
		return
	}
	// PRODUCT_DECISION: escape `</` so the JSON can't accidentally close
	// the surrounding <script> tag.
	blob = bytes.ReplaceAll(blob, []byte("</"), []byte(`<\/`))
	fmt.Fprintf(w, `<script id="recent-data" type="application/json">%s</script>`, blob)
}

// gatherRecentItems walks every conv that includes the viewer plus their
// docs dir, statting each file for its mtime. Returned newest-first.
func gatherRecentItems(user users.User) []recentItem {
	var items []recentItem
	for _, partner := range users.ListAuthorized() {
		if partner.ID == user.ID {
			continue
		}
		conv := chatPairKey(user.ID, partner.ID)
		for _, sid := range ListChatSessions(user.ID, partner.ID) {
			info, err := os.Stat(chatSessionPath(user.ID, partner.ID, sid))
			if err != nil {
				continue
			}
			items = append(items, recentItem{
				kind:       recentChat,
				at:         info.ModTime(),
				partner:    partner.Name,
				conv:       conv,
				sid:        sid,
				lastAuthor: users.GetUserName(ReadChatLastAuthor(user.ID, partner.ID, sid)),
			})
		}
	}
	docs, _ := ListUserDocs(user.ID)
	for _, d := range docs {
		path, err := docPath(user.ID, d.Slug)
		if err != nil {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		items = append(items, recentItem{
			kind:  recentDoc,
			at:    info.ModTime(),
			slug:  d.Slug,
			title: d.Title,
		})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].at.After(items[j].at) })
	return items
}

// recentEvent is one activity ping pushed to a single viewer. Encoded as
// JSON in the SSE data field; the client renders the row from these fields.
// Kind selects which identity fields are populated:
//
//	chat: Conv ("a_b") + SID (topic) + Partner (name of the OTHER side)
//	      + LastAuthor (name of the message's sender)
//	doc:  Slug + Title
type recentEvent struct {
	Kind       string    `json:"kind"`
	At         time.Time `json:"at"`
	Conv       string    `json:"conv,omitempty"`
	SID        string    `json:"sid,omitempty"`
	Partner    string    `json:"partner,omitempty"`
	LastAuthor string    `json:"last_author,omitempty"`
	Slug       string    `json:"slug,omitempty"`
	Title      string    `json:"title,omitempty"`
}

var (
	recentMu sync.Mutex
	// recentSubs is keyed by viewer user id; a user may have multiple tabs
	// open, so each id maps to a set of channels.
	recentSubs = map[string]map[chan recentEvent]struct{}{}
)

// publishRecent delivers an event to every live recent-stream subscriber
// of one user. Best-effort: a full channel is skipped (live-only feed; a
// dropped event just means the user doesn't see that row update until
// next reload or next event). Leaf lock — safe to call while holding
// chatMu (lock order: chatMu -> recentMu).
func publishRecent(userID string, evt recentEvent) {
	recentMu.Lock()
	defer recentMu.Unlock()
	for ch := range recentSubs[userID] {
		select {
		case ch <- evt:
		default:
		}
	}
}

func openRecent(userID string) (<-chan recentEvent, func()) {
	ch := make(chan recentEvent, 16)
	recentMu.Lock()
	if recentSubs[userID] == nil {
		recentSubs[userID] = map[chan recentEvent]struct{}{}
	}
	recentSubs[userID][ch] = struct{}{}
	recentMu.Unlock()

	return ch, func() {
		recentMu.Lock()
		defer recentMu.Unlock()
		if subs := recentSubs[userID]; subs != nil {
			if _, ok := subs[ch]; ok {
				delete(subs, ch)
				close(ch)
			}
			if len(subs) == 0 {
				delete(recentSubs, userID)
			}
		}
	}
}

// PublishChatRecent fans one chat-message activity out to BOTH conv
// participants' recent feeds, pre-resolving each side's partner name +
// the message author's name so the client doesn't need a uid→name table.
// Called from AppendChatMessage (the single chat-write chokepoint).
func PublishChatRecent(conv, sid string, at time.Time, authorUID string) {
	a, b, ok := strings.Cut(conv, "_")
	if !ok || a == "" || b == "" {
		return
	}
	authorName := users.GetUserName(authorUID)
	publishRecent(a, recentEvent{
		Kind: "chat", At: at, Conv: conv, SID: sid,
		Partner: users.GetUserName(b), LastAuthor: authorName,
	})
	publishRecent(b, recentEvent{
		Kind: "chat", At: at, Conv: conv, SID: sid,
		Partner: users.GetUserName(a), LastAuthor: authorName,
	})
}

// PublishDocRecent pings the author's own recent feed when one of their
// docs is created or saved. Docs are per-user, so only the author sees
// them; no fan-out.
func PublishDocRecent(uid, slug string, at time.Time) {
	publishRecent(uid, recentEvent{
		Kind: "doc", At: at, Slug: slug, Title: titleFromSlug(slug),
	})
}

// HandleRecentStream serves GET /chat/recent/stream. Live-only — the
// initial server-rendered table IS the backlog.
func HandleRecentStream(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan recentEvent, func()) {
		return openRecent(user.ID)
	})
}

// RecentJSPath is the embedded recent-feed client (committed, hand-written).
// Served at /chat/recent.js.
var RecentJSPath = "chat/recent.js"

// HandleRecentJS serves the recent-feed client script from the embedded assets.
func HandleRecentJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, RecentJSPath, "recent.js missing from the binary")
}
