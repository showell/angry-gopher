// Page registry. Mounts every HTML route the server serves.
package views

import "net/http"

// RegisterPages wires all page handlers into the mux.
func RegisterPages(mux *http.ServeMux) {
	mux.HandleFunc("/gopher/game-lobby", HandleGames)
	mux.HandleFunc("/gopher/claude", HandleClaudeLanding)
	mux.HandleFunc("/gopher/claude/", HandleClaudeLanding)
	mux.HandleFunc("/gopher/lynrummy-elm/", HandleLynRummyElm)
	mux.HandleFunc("/gopher/lynrummy-elm", HandleLynRummyElm)
	mux.HandleFunc("/gopher/puzzle/", HandlePuzzle)
	mux.HandleFunc("/gopher/puzzle", HandlePuzzle)
	mux.HandleFunc("/gopher/", HandleIndex)
}
