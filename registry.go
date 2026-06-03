// Route registry for the page and chat handlers (login, admin, and
// /version are wired separately in buildMux).
package main

import (
	"angry-gopher/server/chat"
	"angry-gopher/server/home"
	"angry-gopher/server/learn"
	"angry-gopher/server/lynrummy"
	"angry-gopher/server/web"
	"net/http"
)

// RegisterPages wires the page and chat handlers into the mux.
func RegisterPages(mux *http.ServeMux) {
	mux.HandleFunc("/", home.HandleHome)
	mux.HandleFunc("/game", lynrummy.HandleGame)
	mux.HandleFunc("/game/", lynrummy.HandleGame)
	mux.HandleFunc("/puzzles", lynrummy.HandlePuzzles)
	mux.HandleFunc("/puzzles/", lynrummy.HandlePuzzles)
	mux.HandleFunc("/settings", chat.WithPresence(chat.HandleSettings))
	mux.HandleFunc("/settings/apikey", chat.WithPresence(chat.HandleSettingsAPIKey))
	// Path-style URL space (mirrors the on-disk layout):
	//   /chat/c/<conv>/<sid>{,/stream,/send,/upload,/uploads/<file>}
	// /chat/docs* + /chat/chat.js are reserved sub-routes; conv keys are
	// digits-only so they can't collide with those literal names.
	// chat.WithPresence wraps every route that counts as user activity —
	// page nav + discrete POST actions. SSE streams and static JS routes
	// are NOT wrapped (a stream is a long-lived browser subscription, a
	// JS file is a cache hit; neither maps to "user is here right now").
	mux.HandleFunc("/chat", chat.WithPresence(chat.HandleChat))
	mux.HandleFunc("/chat/default", chat.WithPresence(chat.HandleChatDefault))
	mux.HandleFunc("/chat/recent", chat.WithPresence(chat.HandleRecent))
	mux.HandleFunc("/chat/recent/stream", chat.HandleRecentStream)
	mux.HandleFunc("/chat/sidebar/stream", chat.HandleSidebarStream)
	mux.HandleFunc("/chat/recent.js", chat.HandleRecentJS)
	mux.HandleFunc("/chat/images", chat.WithPresence(chat.HandleImages))
	mux.HandleFunc("/chat/images/stream", chat.HandleImagesStream)
	mux.HandleFunc("/chat/images.js", chat.HandleImagesJS)
	mux.HandleFunc("/chat/code", chat.WithPresence(chat.HandleCode))
	mux.HandleFunc("/chat/code/stream", chat.HandleCodeStream)
	mux.HandleFunc("/chat/code.js", chat.HandleCodeJS)
	mux.HandleFunc("/chat/conversations", chat.WithPresence(chat.HandleChatConversations))
	mux.HandleFunc("/chat/notifications", chat.HandleChatNotifications)
	mux.HandleFunc("/chat/chat.js", chat.HandleChatJS)
	mux.HandleFunc("/chat/styles.js", chat.HandleStylesJS)
	mux.HandleFunc("/chat/colors.js", chat.HandleColorsJS)
	mux.HandleFunc("/chat/chat_theme.js", chat.HandleChatThemeJS)
	mux.HandleFunc("/chat/chat_search.js", chat.HandleChatSearchJS)
	mux.HandleFunc("/chat/chat_left_sidebar.js", chat.HandleChatLeftSidebarJS)
	mux.HandleFunc("/chat/chat_add_topic.js", chat.HandleChatAddTopicJS)
	mux.HandleFunc("/chat/chat_drag_to_pin.js", chat.HandleChatDragToPinJS)
	mux.HandleFunc("/chat/chat_right_sidebar.js", chat.HandleChatRightSidebarJS)
	mux.HandleFunc("/chat/chat_compose.js", chat.HandleChatComposeJS)
	mux.HandleFunc("/chat/chat_help.js", chat.HandleChatHelpJS)
	mux.HandleFunc("/chat/message.js", chat.HandleMessageJS)
	mux.HandleFunc("/chat/message_view.js", chat.HandleMessageViewJS)
	mux.HandleFunc("/chat/nav_stack.js", chat.HandleNavStackJS)
	mux.HandleFunc("/chat/middle_pane.js", chat.HandleMiddlePaneJS)
	mux.HandleFunc("/chat/chat_image_popup.js", chat.HandleChatImagePopupJS)
	mux.HandleFunc("/chat/chat_code_popup.js", chat.HandleChatCodePopupJS)
	mux.HandleFunc("/chat/notify.js", chat.HandleNotifyJS)
	mux.HandleFunc("/chat/c/{conv}", chat.WithPresence(chat.HandleChatConv))
	mux.HandleFunc("/chat/c/{conv}/new", chat.WithPresence(chat.HandleChatNewTopic)) // literal beats {sid}; "new" reserved
	mux.HandleFunc("/chat/c/{conv}/{sid}", chat.WithPresence(chat.HandleChatPage))
	mux.HandleFunc("/chat/c/{conv}/{sid}/stream", chat.HandleChatStream)
	mux.HandleFunc("/chat/c/{conv}/{sid}/send", chat.WithPresence(chat.HandleChatSend))
	mux.HandleFunc("/chat/c/{conv}/{sid}/pin", chat.WithPresence(chat.HandleChatPin))
	mux.HandleFunc("/chat/c/{conv}/{sid}/unpin", chat.WithPresence(chat.HandleChatPin))
	mux.HandleFunc("/chat/c/{conv}/{sid}/upload", chat.WithPresence(chat.HandleChatUpload))
	mux.HandleFunc("/chat/c/{conv}/{sid}/uploads/{file}", chat.HandleChatFile)
	mux.HandleFunc("/chat/docs", chat.WithPresence(chat.HandleDocs))
	mux.HandleFunc("/chat/docs.js", chat.HandleDocsJS)
	mux.HandleFunc("/chat/docs/list", chat.WithPresence(chat.HandleDocsList))
	mux.HandleFunc("/chat/docs/new", chat.WithPresence(chat.HandleDocsNew))
	mux.HandleFunc("/chat/docs/save", chat.WithPresence(chat.HandleDocsSave))
	mux.HandleFunc("/chat/docs/render", chat.WithPresence(chat.HandleDocsRender))
	mux.HandleFunc("/chat/docs/post", chat.WithPresence(chat.HandleDocsPost))
	// Path-style doc URLs (mirror users/<uid>/docs/<slug>.md): /chat/docs/<slug>
	// is the editor, /chat/docs/<slug>.md the raw file. Registered after the
	// literal verbs above, which Go 1.22's ServeMux prefers over this wildcard.
	mux.HandleFunc("/chat/docs/{slug}", chat.WithPresence(chat.HandleDocsItem))
	// /learn — tutorial page (top-level, unauthed). See server/learn.
	mux.HandleFunc("/learn", learn.HandleLearn)
	mux.HandleFunc("/learn/learn.js", learn.HandleLearnJS)
	mux.HandleFunc("/learn/callback_log.js", learn.HandleCallbackLogJS)
	mux.HandleFunc("/learn/fake_host.js", learn.HandleFakeHostJS)
	mux.HandleFunc("/learn/source/{file}", learn.HandleLearnSource)
	// /images/<file> — shared brand assets (avatars etc). Explicit
	// allowlist lives in server/web/images.go.
	mux.HandleFunc("/images/{file}", web.HandleImage)
}
