// Route registry for the page and chat handlers (login, admin, and
// /version are wired separately in buildMux).
package main

import (
	"angry-gopher/server/chat"
	"angry-gopher/server/home"
	"angry-gopher/server/lynrummy"
	"net/http"
)

// RegisterPages wires the page and chat handlers into the mux.
func RegisterPages(mux *http.ServeMux) {
	mux.HandleFunc("/", home.HandleHome)
	mux.HandleFunc("/game", lynrummy.HandleGame)
	mux.HandleFunc("/game/", lynrummy.HandleGame)
	mux.HandleFunc("/puzzles", lynrummy.HandlePuzzles)
	mux.HandleFunc("/puzzles/", lynrummy.HandlePuzzles)
	mux.HandleFunc("/settings", chat.HandleSettings)
	mux.HandleFunc("/settings/apikey", chat.HandleSettingsAPIKey)
	// Path-style URL space (mirrors the on-disk layout):
	//   /chat/c/<conv>/<sid>{,/stream,/send,/upload,/uploads/<file>}
	// /chat/docs* + /chat/chat.js are reserved sub-routes; conv keys are
	// digits-only so they can't collide with those literal names.
	mux.HandleFunc("/chat", chat.HandleChat)
	mux.HandleFunc("/chat/default", chat.HandleChatDefault)
	mux.HandleFunc("/chat/conversations", chat.HandleChatConversations)
	mux.HandleFunc("/chat/notifications", chat.HandleChatNotifications)
	mux.HandleFunc("/chat/chat.js", chat.HandleChatJS)
	mux.HandleFunc("/chat/notify.js", chat.HandleNotifyJS)
	mux.HandleFunc("/chat/c/{conv}", chat.HandleChatConv)
	mux.HandleFunc("/chat/c/{conv}/new", chat.HandleChatNewTopic) // literal beats {sid}; "new" reserved
	mux.HandleFunc("/chat/c/{conv}/{sid}", chat.HandleChatPage)
	mux.HandleFunc("/chat/c/{conv}/{sid}/stream", chat.HandleChatStream)
	mux.HandleFunc("/chat/c/{conv}/{sid}/send", chat.HandleChatSend)
	mux.HandleFunc("/chat/c/{conv}/{sid}/pin", chat.HandleChatPin)
	mux.HandleFunc("/chat/c/{conv}/{sid}/unpin", chat.HandleChatPin)
	mux.HandleFunc("/chat/c/{conv}/{sid}/upload", chat.HandleChatUpload)
	mux.HandleFunc("/chat/c/{conv}/{sid}/uploads/{file}", chat.HandleChatFile)
	mux.HandleFunc("/chat/docs", chat.HandleDocs)
	mux.HandleFunc("/chat/docs.js", chat.HandleDocsJS)
	mux.HandleFunc("/chat/docs/list", chat.HandleDocsList)
	mux.HandleFunc("/chat/docs/new", chat.HandleDocsNew)
	mux.HandleFunc("/chat/docs/save", chat.HandleDocsSave)
	mux.HandleFunc("/chat/docs/render", chat.HandleDocsRender)
	mux.HandleFunc("/chat/docs/post", chat.HandleDocsPost)
	// Path-style doc URLs (mirror users/<uid>/docs/<slug>.md): /chat/docs/<slug>
	// is the editor, /chat/docs/<slug>.md the raw file. Registered after the
	// literal verbs above, which Go 1.22's ServeMux prefers over this wildcard.
	mux.HandleFunc("/chat/docs/{slug}", chat.HandleDocsItem)
}
