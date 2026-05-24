// Page registry. Mounts every HTML route the server serves.
package views

import (
	"angry-gopher/server/chat"
	"angry-gopher/server/lynrummy"
	"net/http"
)

// RegisterPages wires all page handlers into the mux.
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
