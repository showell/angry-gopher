// /chat/recent: a flat reverse-chronological feed of activity across the
// signed-in user's chat sessions and personal docs. Initial-load source
// is file mtime (the server walks the convs the user participates in
// plus their docs dir on every GET). After load, a per-user SSE stream
// (/chat/recent/stream) delivers one event per write, and a 20-second
// client-side timer re-humanizes the When column without a round-trip.
package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/platform"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
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
	// chat-only — pre-resolved via the Conv abstraction, exactly like the live
	// path (publishRecentForConv), so DM and channel rows are shaped identically.
	url        string // topic page URL (/chat/c/... for DMs, /channel/... for channels)
	where      string // muted context ("with apoorva" / "in General")
	topic      string // the session/topic id (display label)
	lastAuthor string // display name of the most recent sender, or ""
	excerpt    string // plain-text preview of the latest message (client clamps to 3 lines)
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
		url.QueryEscape(platform.AssetVersion), url.QueryEscape(platform.AssetVersion))
	platform.PageFooter(w)
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
			evt.URL = it.url
			evt.Topic = it.topic
			evt.Where = it.where
			evt.LastAuthor = it.lastAuthor
			evt.Excerpt = it.excerpt
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

// gatherRecentItems walks every conv that includes the viewer — DMs AND the
// channels they're a member of — plus their docs dir, statting each session
// file for its mtime. Returned newest-first. DMs and channels go through the
// same Conv methods (topicURL / recentWhereFor / LastAuthor), so a channel
// topic shows up here exactly like a DM topic, just with "in <channel>" context.
func gatherRecentItems(user users.User) []recentItem {
	var items []recentItem
	var convs []Conv
	for _, partner := range users.ListAuthorized() {
		if partner.ID == user.ID {
			continue
		}
		convs = append(convs, DMConv(user.ID, partner.ID))
	}
	for _, name := range ListUserChannels(user.ID) {
		if c, ok := ChannelConv(name, user.ID); ok {
			convs = append(convs, c)
		}
	}
	for _, c := range convs {
		for _, sid := range c.ListSessions() {
			info, err := os.Stat(c.SessionPath(sid))
			if err != nil {
				continue
			}
			items = append(items, recentItem{
				kind:       recentChat,
				at:         info.ModTime(),
				url:        c.topicURL(sid),
				where:      c.recentWhereFor(user.ID),
				topic:      sid,
				lastAuthor: users.GetUserName(c.LastAuthor(sid)),
				excerpt:    recentExcerpt(lastMessageMarkdown(c, sid)),
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

// recentEvent is one activity ping pushed to a single viewer. Kind
// selects which fields are populated:
//
//	chat: URL (where to navigate) + Topic (display label for the topic)
//	      + Where (pre-rendered context, "with apoorva" for DMs or
//	      "in General" for channels) + LastAuthor (sender's name)
//	doc:  Slug + Title
//
// Pre-rendering URL + Where on the server means the client doesn't
// branch on conv shape: every chat row is "Message from <LastAuthor>
// in <Topic> (<Where>)" linking to URL, no conditional.
type recentEvent struct {
	Kind       string    `json:"kind"`
	At         time.Time `json:"at"`
	URL        string    `json:"url,omitempty"`
	Topic      string    `json:"topic,omitempty"`
	Where      string    `json:"where,omitempty"`
	LastAuthor string    `json:"last_author,omitempty"`
	Excerpt    string    `json:"excerpt,omitempty"`
	Slug       string    `json:"slug,omitempty"`
	Title      string    `json:"title,omitempty"`
}

// recentBus is keyed by viewer user id.
var recentBus = newSubBus[recentEvent]()

// publishRecentForConv fans one chat-message activity out to every
// conv member's recent feed, pre-resolving the per-recipient "Where"
// label so the client doesn't need a uid→name table. DM: each side
// reads "with <other>"; channel: every member reads "in <channel>".
func publishRecentForConv(c Conv, sid string, at time.Time, authorUID, markdown string) {
	authorName := users.GetUserName(authorUID)
	url := c.topicURL(sid)
	excerpt := recentExcerpt(markdown)
	for _, uid := range c.Members {
		recentBus.publish(uid, recentEvent{
			Kind:       "chat",
			At:         at,
			URL:        url,
			Topic:      sid,
			Where:      c.recentWhereFor(uid),
			LastAuthor: authorName,
			Excerpt:    excerpt,
		})
	}
}

// recentExcerptCap bounds the excerpt's byte size on the wire. The client
// visually clamps the cell to 3 lines; this just keeps a long message from
// bloating the feed JSON.
const recentExcerptCap = 280

var (
	imgTagRe  = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	mdImageRe = regexp.MustCompile(`!\[[^\]]*\]\([^)]*\)`)
	wsRunRe   = regexp.MustCompile(`\s+`)
)

// recentExcerpt renders a one-line plain-text preview of a message's raw
// markdown for the Recent feed: image tags (HTML or markdown) collapse to
// "[image]", all whitespace runs become a single space, and the result is
// capped at recentExcerptCap runes. The client CSS-clamps the visible height
// to three lines.
func recentExcerpt(markdown string) string {
	s := imgTagRe.ReplaceAllString(markdown, "[image]")
	s = mdImageRe.ReplaceAllString(s, "[image]")
	s = strings.TrimSpace(wsRunRe.ReplaceAllString(s, " "))
	if r := []rune(s); len(r) > recentExcerptCap {
		s = strings.TrimSpace(string(r[:recentExcerptCap])) + "…"
	}
	return s
}

// lastMessageMarkdown returns the raw markdown of the most recent message in
// a session, or "" if it's empty or unreadable. Reads the whole transcript —
// fine at our scale (the Recent page already stats every session file on GET).
func lastMessageMarkdown(c Conv, sid string) string {
	msgs, err := c.ReadSession(sid)
	if err != nil || len(msgs) == 0 {
		return ""
	}
	return msgs[len(msgs)-1].Markdown
}

// recentWhereFor is the per-recipient muted-span text. DMs name the
// other party ("with apoorva"); channels name the channel ("in General").
func (c Conv) recentWhereFor(viewerUID string) string {
	if c.Kind == KindChannel {
		return "in " + c.Key
	}
	other := c.PartnerOf(viewerUID)
	return "with " + users.GetUserName(other)
}

// PublishDocRecent pings the author's own recent feed when one of their
// docs is created or saved. Docs are per-user, so only the author sees
// them; no fan-out.
func PublishDocRecent(uid, slug string, at time.Time) {
	recentBus.publish(uid, recentEvent{
		Kind: "doc", At: at, Slug: slug, Title: titleFromSlug(slug),
	})
}

// HandleRecentStream serves GET /chat/recent/stream. Live-only — the
// initial server-rendered table IS the backlog.
func HandleRecentStream(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan recentEvent, func()) {
		return recentBus.open(user.ID)
	})
}

// RecentJSPath is the embedded recent-feed client (committed, hand-written).
// Served at /chat/recent.js.
var RecentJSPath = "chat/recent.js"

// HandleRecentJS serves the recent-feed client script from the embedded assets.
func HandleRecentJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, RecentJSPath, "recent.js missing from the binary")
}
