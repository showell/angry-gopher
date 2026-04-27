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
func GetPages() []PageDef {
	hardcoded := []PageDef{
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
func RegisterPages(mux *http.ServeMux) {
	for _, p := range GetPages() {
		mux.HandleFunc(p.Path, p.Handler)
	}
	mux.HandleFunc("/gopher/tour", HandleTour)
	mux.HandleFunc("/gopher/quicknav", HandleQuickNav)
	mux.HandleFunc("/gopher/nav", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "views/static_nav.html")
	})
	mux.HandleFunc("/gopher/claude", HandleClaudeLanding)
	mux.HandleFunc("/gopher/claude/", HandleClaudeLanding)
	mux.HandleFunc("/gopher/docs/", HandleDocs)
	mux.HandleFunc("/gopher/docs", HandleDocs)
	mux.HandleFunc("/gopher/code/", HandleCode)
	mux.HandleFunc("/gopher/code", HandleCode)
	mux.HandleFunc("/gopher/wiki/", HandleWikiLegacy)
	mux.HandleFunc("/gopher/wiki", HandleWikiLegacy)
	mux.HandleFunc("/gopher/lynrummy-elm/", HandleLynRummyElm)
	mux.HandleFunc("/gopher/lynrummy-elm", HandleLynRummyElm)
	mux.HandleFunc("/gopher/puzzles/", HandlePuzzles)
	mux.HandleFunc("/gopher/puzzles", HandlePuzzles)
	mux.HandleFunc("/gopher/", HandleIndex)
}
