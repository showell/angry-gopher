// /chat/recent: a flat reverse-chronological feed of activity across the
// signed-in user's chat sessions and personal docs. v1 source is just file
// mtime — the server walks the convs the user participates in plus their
// docs dir, formats relative ages, and emits one link per item. Completely
// static; no SSE. At our current scale (a handful of users, a few topics
// each) one O(files) stat-walk per request is fine. SSE + smarter
// per-subscriber event tracking can layer on once the client shape stabilizes.

package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"sort"
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
	partner string
	conv    string
	sid     string
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
	renderRecentList(w, items)
	web.PageFooter(w)
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
				kind:    recentChat,
				at:      info.ModTime(),
				partner: partner.Name,
				conv:    conv,
				sid:     sid,
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

func renderRecentList(w http.ResponseWriter, items []recentItem) {
	if len(items) == 0 {
		fmt.Fprint(w, `<p class="muted">Nothing yet.</p>`)
		return
	}
	fmt.Fprint(w, `<ul class="recent-list">`)
	for _, it := range items {
		age := web.HumanizeSince(it.at)
		switch it.kind {
		case recentChat:
			href := "/chat/c/" + it.conv + "/" + url.PathEscape(it.sid)
			fmt.Fprintf(w,
				`<li><span class="recent-age muted">%s</span> · New message in <a href="%s">%s</a> <span class="muted">(with %s)</span></li>`,
				html.EscapeString(age), href,
				html.EscapeString(it.sid), html.EscapeString(it.partner))
		case recentDoc:
			href := "/chat/docs/" + url.PathEscape(it.slug)
			fmt.Fprintf(w,
				`<li><span class="recent-age muted">%s</span> · You edited <a href="%s">%s</a></li>`,
				html.EscapeString(age), href, html.EscapeString(it.title))
		}
	}
	fmt.Fprint(w, `</ul>`)
}
