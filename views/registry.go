// Page registry. Mounts every HTML route the server serves.
package views

import "net/http"

// RegisterPages wires all page handlers into the mux.
func RegisterPages(mux *http.ServeMux) {
	mux.HandleFunc("/", HandleHome)
	mux.HandleFunc("/game", HandleGame)
	mux.HandleFunc("/game/", HandleGame)
	mux.HandleFunc("/puzzles", HandlePuzzles)
	mux.HandleFunc("/puzzles/", HandlePuzzles)
	mux.HandleFunc("/chat", HandleChat)
	mux.HandleFunc("/chat/send", HandleChatSend)
	mux.HandleFunc("/chat/stream", HandleChatStream)
	mux.HandleFunc("/chat/upload", HandleChatUpload)
	mux.HandleFunc("/chat/uploads/", HandleChatFile)
}
