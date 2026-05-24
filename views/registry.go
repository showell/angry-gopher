// Page registry. Mounts every HTML route the server serves.
package views

import (
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
	mux.HandleFunc("/settings", HandleSettings)
	mux.HandleFunc("/settings/apikey", HandleSettingsAPIKey)
	mux.HandleFunc("/chat", HandleChat)
	mux.HandleFunc("/chat/chat.js", HandleChatJS)
	mux.HandleFunc("/chat/send", HandleChatSend)
	mux.HandleFunc("/chat/stream", HandleChatStream)
	mux.HandleFunc("/chat/upload", HandleChatUpload)
	mux.HandleFunc("/chat/uploads/", HandleChatFile)
}
