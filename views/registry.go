// Page registry — single source of truth for all CRUD pages.
// The nav bar, index page, and tour page all read from this.
// To add a new page: add an entry here and create the handler.
package views

import "net/http"

// PageDef describes a CRUD page.
type PageDef struct {
	Path      string
	NavLabel  string // short label for nav bar
	Title     string // full title for index/tour
	Subtitle  string // help/marketing blurb
	Handler   http.HandlerFunc
	AdminOnly bool
}

// Pages returns the ordered list of all CRUD pages.
// This is a function (not a var) to avoid an initialization cycle
// between Pages → handlers → PageHeader → Pages.
//
// Pages declared in crudgen .claude files self-register via
// generatedPages (see registry_generated.go) and appear after
// the hardcoded list below.
func GetPages() []PageDef {
	hardcoded := []PageDef{
	{
		Path:     "/gopher/messages",
		NavLabel: "Messages",
		Title:    "Messages",
		Subtitle: "Browse channels and topics. Messages stream progressively — no waiting for large topics to load.",
		Handler:  HandleMessages,
	},
	{
		Path:     "/gopher/recent",
		NavLabel: "Recent",
		Title:    "Recent Conversations",
		Subtitle: "Topics with the most recent activity across all your channels.",
		Handler:  HandleRecent,
	},
	{
		Path:     "/gopher/unread",
		NavLabel: "Unread",
		Title:    "Unread Messages",
		Subtitle: "Topics where you have unread messages. Click to catch up.",
		Handler:  HandleUnread,
	},
	{
		Path:     "/gopher/starred",
		NavLabel: "Starred",
		Title:    "Starred Messages",
		Subtitle: "Messages you've starred for quick reference. Stars persist across sessions.",
		Handler:  HandleStarred,
	},
	{
		Path:     "/gopher/search",
		NavLabel: "Search",
		Title:    "Search",
		Subtitle: "Find any message by text, channel, topic, or sender. Trigram search finds URLs and code snippets that other chat apps miss.",
		Handler:  HandleSearch,
	},
	{
		Path:     "/gopher/channels",
		NavLabel: "Channels",
		Title:    "Channels",
		Subtitle: "Public and private channels. Click any channel name to browse its topics.",
		Handler:  HandleChannels,
	},
	{
		Path:     "/gopher/dm",
		NavLabel: "DMs",
		Title:    "Direct Messages",
		Subtitle: "Private 1:1 conversations.",
		Handler:  HandleDM,
	},
	{
		Path:     "/gopher/users",
		NavLabel: "Users",
		Title:    "Users",
		Subtitle: "Everyone in your organization. Click a name to see their channels and start a DM.",
		Handler:  HandleUsers,
	},
	{
		Path:     "/gopher/game-lobby",
		NavLabel: "Games",
		Title:    "Games",
		Subtitle: "Play LynRummy and other games with your team — right inside your chat app.",
		Handler:  HandleGames,
	},
	}
	return append(hardcoded, generatedPages...)
}

// RegisterPages wires all page handlers into the mux.
// Also registers the index, tour, and utility routes.
func RegisterPages(mux *http.ServeMux) {
	for _, p := range GetPages() {
		mux.HandleFunc(p.Path, p.Handler)
	}
	mux.HandleFunc("/gopher/tour", HandleTour)
	mux.HandleFunc("/gopher/quicknav", HandleQuickNav)
	mux.HandleFunc("/gopher/nav", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "views/static_nav.html")
	})
	mux.HandleFunc("/gopher/sse/messages", HandleSSEMessages)
	mux.HandleFunc("/gopher/sse/events", HandleSSEEvents)
	mux.HandleFunc("/gopher/", HandleIndex)
}
