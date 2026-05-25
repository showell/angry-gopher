// Route registry for the page and chat handlers (login, admin, and
// /version are wired separately in buildMux).
package main

import (
	"angry-gopher/server/chat"
	"angry-gopher/server/lynrummy"
	"net/http"
)

// RegisterPages wires the page and chat handlers into the mux.
func RegisterPages(mux *http.ServeMux) {
	mux.HandleFunc("/", HandleHome)
	mux.HandleFunc("/game", lynrummy.HandleGame)
	mux.HandleFunc("/game/", lynrummy.HandleGame)
	mux.HandleFunc("/puzzles", lynrummy.HandlePuzzles)
	mux.HandleFunc("/puzzles/", lynrummy.HandlePuzzles)
	mux.HandleFunc("/settings", chat.HandleSettings)
	mux.HandleFunc("/settings/apikey", chat.HandleSettingsAPIKey)
	mux.HandleFunc("/chat", chat.HandleChat)
	mux.HandleFunc("/chat/chat.js", chat.HandleChatJS)
	mux.HandleFunc("/chat/send", chat.HandleChatSend)
	mux.HandleFunc("/chat/stream", chat.HandleChatStream)
	mux.HandleFunc("/chat/upload", chat.HandleChatUpload)
	mux.HandleFunc("/chat/uploads/", chat.HandleChatFile)
}
