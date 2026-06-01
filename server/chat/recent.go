// /chat/recent: a flat reverse-chronological feed of activity across the
// signed-in user's chat sessions and personal docs.
//
// Initial-load source is file mtime (the server walks the convs the user
// participates in plus their docs dir on every GET). After load, the page
// stays live two ways:
//   - a per-user SSE stream at /chat/recent/stream, with one event per
//     write — AppendChatMessage / WriteUserDoc / CreateUserDoc call into
//     PublishChatRecent / PublishDocRecent at the source.
//   - a 20-second client-side timer that re-humanizes the When column
//     from each row's data-ts (so "5m ago" rolls to "6m ago" without a
//     server round-trip).
//
// SSE landscape (three streams, one file each):
//   - chat-message  chat_stream.go:  /chat/c/{conv}/{sid}/stream
//                                    (full rendered messages for ONE open session)
//   - notify        chat_notify.go:  /chat/notifications
//                                    (per-user pings + favicon-violet)
//   - recent        (HERE):          /chat/recent/stream
//                                    (per-user row upserts for the Recent page)
//
// Publish chokepoints: chat_store.go::AppendChatMessage publishes for
// chat events (to BOTH participants); docs_store.go::WriteUserDoc and
// CreateUserDoc publish for doc events (author only). Per-user
// subscriber map mirrors chat_notify.go — same shape, same flush + ping
// rhythm, just a richer event payload (kind + identity fields).

package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"encoding/json"
	"fmt"
	"html"
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
	fmt.Fprint(w, recentCSS)
	renderRecentList(w, items)
	fmt.Fprintf(w, `<script src="/chat/recent.js?v=%s"></script>`+
		`<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion))
	web.PageFooter(w)
}

// recentCSS scopes the When column's right-align + tabular-nums to the
// recent page. The shared chrome already styles the table (border, hover,
// header color); this only adds what's specific to recent's first column.
const recentCSS = `<style>
.recent-table th.recent-when, .recent-table td.recent-when {
  text-align: right; font-variant-numeric: tabular-nums;
  white-space: nowrap; width: 1%;
}
.recent-table td.recent-when { color: #888; }
</style>`

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

// renderRecentList emits the activity table. Every <tr> carries a
// data-key (kind:identity, so SSE upserts replace the right row) and a
// data-ts (RFC3339, so the 20s client tick can re-humanize the When cell
// without a server round-trip). The empty-state <p> uses id="recent-empty"
// so SSE can swap it out for the table on first event.
//
// <thead> + <tbody> are emitted EXPLICITLY: browsers auto-wrap loose <tr>s
// in a tbody anyway, and the JS targets that tbody when inserting new
// rows. Pretending the tbody doesn't exist in the source means JS that
// queries `table > tr` is structurally wrong but coincidentally works
// for queries-as-descendants — and crashes on insertBefore.
func renderRecentList(w http.ResponseWriter, items []recentItem) {
	fmt.Fprint(w, `<table class="recent-table" id="recent-table"`)
	if len(items) == 0 {
		fmt.Fprint(w, ` hidden`)
	}
	fmt.Fprint(w, `><thead><tr><th class="recent-when">When</th><th>What</th></tr></thead><tbody>`)
	for _, it := range items {
		writeRecentRow(w, it)
	}
	fmt.Fprint(w, `</tbody></table>`)
	if len(items) == 0 {
		fmt.Fprint(w, `<p class="muted" id="recent-empty">Nothing yet.</p>`)
	}
}

func writeRecentRow(w http.ResponseWriter, it recentItem) {
	age := web.HumanizeSince(it.at)
	ts := it.at.UTC().Format(time.RFC3339)
	switch it.kind {
	case recentChat:
		href := "/chat/c/" + it.conv + "/" + url.PathEscape(it.sid)
		key := "chat:" + it.conv + "/" + it.sid
		// PRODUCT_DECISION: lead with the author when known — that's what
		// apoorva asked for. Fall back to the older "New message" phrasing
		// when the companion file is missing (pre-companion sessions before
		// the migration backfill).
		var what string
		if it.lastAuthor != "" {
			what = fmt.Sprintf(
				`Message from <strong>%s</strong> in <a href="%s">%s</a> <span class="muted">(with %s)</span>`,
				html.EscapeString(it.lastAuthor), href,
				html.EscapeString(it.sid), html.EscapeString(it.partner))
		} else {
			what = fmt.Sprintf(
				`New message in <a href="%s">%s</a> <span class="muted">(with %s)</span>`,
				href, html.EscapeString(it.sid), html.EscapeString(it.partner))
		}
		fmt.Fprintf(w,
			`<tr data-key="%s" data-ts="%s"><td class="recent-when">%s</td><td>%s</td></tr>`,
			html.EscapeString(key), ts, html.EscapeString(age), what)
	case recentDoc:
		href := "/chat/docs/" + url.PathEscape(it.slug)
		key := "doc:" + it.slug
		fmt.Fprintf(w,
			`<tr data-key="%s" data-ts="%s"><td class="recent-when">%s</td>`+
				`<td>You edited <a href="%s">%s</a></td></tr>`,
			html.EscapeString(key), ts, html.EscapeString(age), href,
			html.EscapeString(it.title))
	}
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

// openRecent registers a subscriber for one viewer; the returned cancel
// unregisters and closes its channel.
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

// HandleRecentStream is the per-user SSE stream of activity events for
// the recent feed (GET /chat/recent/stream). Mirrors HandleChatNotifications:
// live-only, no backlog, no replay — the initial server-rendered table
// IS the backlog. Cleared write-deadline + 25s ping keepalives.
func HandleRecentStream(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	ch, cancel := openRecent(user.ID)
	defer cancel()

	if _, err := fmt.Fprint(w, ": ok\n\n"); err != nil {
		return
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
			blob, err := json.Marshal(evt)
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", blob); err != nil {
				return
			}
			if rc.Flush() != nil {
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

// RecentJSPath is the embedded recent-feed client (committed, hand-written).
// Served at /chat/recent.js.
var RecentJSPath = "chat/recent.js"

// HandleRecentJS serves the recent-feed client script from the embedded assets.
func HandleRecentJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, RecentJSPath, "recent.js missing from the binary")
}
