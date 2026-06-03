// Route registry. Every page, asset, and stream is registered here
// with its authorization strategy (see auth.go). The strategy is the
// authoritative gate — handlers do not re-check.
package main

import (
	"angry-gopher/server/admin"
	"angry-gopher/server/chat"
	"angry-gopher/server/home"
	"angry-gopher/server/learn"
	"angry-gopher/server/login"
	"angry-gopher/server/lynrummy"
	"angry-gopher/server/platform"
	"net/http"
)

// RegisterPages wires every route into the mux. Patterns are grouped by
// surface (home, lynrummy, login, chat, learn, admin, assets); within
// a group the strategy column is uniform unless the path itself names
// the exception.
func RegisterPages(mux *http.ServeMux) {
	// Home + version: anyone.
	Route(mux, "/", TOTALLY_PUBLIC, home.HandleHome)
	Route(mux, "/version", TOTALLY_PUBLIC, handleVersion)

	// Lyn Rummy.
	Route(mux, "/game", JUST_NEEDS_NAME, lynrummy.HandleGame)
	Route(mux, "/game/", JUST_NEEDS_NAME, lynrummy.HandleGame)
	Route(mux, "/puzzles", JUST_NEEDS_NAME, lynrummy.HandlePuzzles)
	Route(mux, "/puzzles/", JUST_NEEDS_NAME, lynrummy.HandlePuzzles)

	// Login surface itself is anyone — that's the whole point.
	Route(mux, "/login", TOTALLY_PUBLIC, login.HandleLogin)
	Route(mux, "/login/full", TOTALLY_PUBLIC, login.HandleLoginFull)
	Route(mux, "/logout", TOTALLY_PUBLIC, login.HandleLogout)

	// Chat. Pages + discrete actions go through WithPresence (marks
	// the caller active on every hit). Streams + static JS deliberately
	// don't — a stream is a long-lived browser subscription, a JS file
	// is a cache hit; neither maps to "user is here right now."
	Route(mux, "/settings", NEED_PASSWORD, chat.WithPresence(chat.HandleSettings))
	Route(mux, "/settings/apikey", NEED_PASSWORD, chat.WithPresence(chat.HandleSettingsAPIKey))

	// /chat/c/<conv>/<sid>{,/stream,/send,/upload,/uploads/<file>} —
	// path-style URL space mirrors the on-disk layout. /chat/docs* +
	// /chat/chat.js are reserved sub-routes; conv keys are digits-only
	// so they can't collide with those literal names.
	Route(mux, "/chat", NEED_PASSWORD, chat.WithPresence(chat.HandleChat))
	Route(mux, "/chat/default", NEED_PASSWORD, chat.WithPresence(chat.HandleChatDefault))
	Route(mux, "/chat/recent", NEED_PASSWORD, chat.WithPresence(chat.HandleRecent))
	Route(mux, "/chat/recent/stream", NEED_PASSWORD, chat.HandleRecentStream)
	Route(mux, "/chat/sidebar/stream", NEED_PASSWORD, chat.HandleSidebarStream)
	Route(mux, "/chat/images", NEED_PASSWORD, chat.WithPresence(chat.HandleImages))
	Route(mux, "/chat/images/stream", NEED_PASSWORD, chat.HandleImagesStream)
	Route(mux, "/chat/code", NEED_PASSWORD, chat.WithPresence(chat.HandleCode))
	Route(mux, "/chat/code/stream", NEED_PASSWORD, chat.HandleCodeStream)
	Route(mux, "/chat/conversations", NEED_PASSWORD, chat.WithPresence(chat.HandleChatConversations))
	Route(mux, "/chat/notifications", NEED_PASSWORD, chat.HandleChatNotifications)
	Route(mux, "/chat/c/{conv}", NEED_PASSWORD, chat.WithPresence(chat.HandleChatConv))
	Route(mux, "/chat/c/{conv}/new", NEED_PASSWORD, chat.WithPresence(chat.HandleChatNewTopic)) // literal beats {sid}; "new" reserved
	Route(mux, "/chat/c/{conv}/{sid}", NEED_PASSWORD, chat.WithPresence(chat.HandleChatPage))
	Route(mux, "/chat/c/{conv}/{sid}/stream", NEED_PASSWORD, chat.HandleChatStream)
	Route(mux, "/chat/c/{conv}/{sid}/send", NEED_PASSWORD, chat.WithPresence(chat.HandleChatSend))
	Route(mux, "/chat/c/{conv}/{sid}/pin", NEED_PASSWORD, chat.WithPresence(chat.HandleChatPin))
	Route(mux, "/chat/c/{conv}/{sid}/unpin", NEED_PASSWORD, chat.WithPresence(chat.HandleChatPin))
	Route(mux, "/chat/c/{conv}/{sid}/upload", NEED_PASSWORD, chat.WithPresence(chat.HandleChatUpload))
	Route(mux, "/chat/c/{conv}/{sid}/uploads/{file}", NEED_PASSWORD, chat.HandleChatFile)
	Route(mux, "/chat/docs", NEED_PASSWORD, chat.WithPresence(chat.HandleDocs))
	Route(mux, "/chat/docs/list", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsList))
	Route(mux, "/chat/docs/new", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsNew))
	Route(mux, "/chat/docs/save", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsSave))
	Route(mux, "/chat/docs/render", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsRender))
	Route(mux, "/chat/docs/post", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsPost))
	// Path-style doc URLs (mirror users/<uid>/docs/<slug>.md): /chat/docs/<slug>
	// is the editor, /chat/docs/<slug>.md the raw file. Registered after the
	// literal verbs above, which Go 1.22's ServeMux prefers over this wildcard.
	Route(mux, "/chat/docs/{slug}", NEED_PASSWORD, chat.WithPresence(chat.HandleDocsItem))

	// Chat JS bundles — static cacheable assets. Loaded by /learn too
	// (which itself is TOTALLY_PUBLIC), so these must be public.
	Route(mux, "/chat/recent.js", TOTALLY_PUBLIC, chat.HandleRecentJS)
	Route(mux, "/chat/images.js", TOTALLY_PUBLIC, chat.HandleImagesJS)
	Route(mux, "/chat/code.js", TOTALLY_PUBLIC, chat.HandleCodeJS)
	Route(mux, "/chat/chat.js", TOTALLY_PUBLIC, chat.HandleChatJS)
	Route(mux, "/chat/styles.js", TOTALLY_PUBLIC, chat.HandleStylesJS)
	Route(mux, "/chat/colors.js", TOTALLY_PUBLIC, chat.HandleColorsJS)
	Route(mux, "/chat/chat_theme.js", TOTALLY_PUBLIC, chat.HandleChatThemeJS)
	Route(mux, "/chat/chat_search.js", TOTALLY_PUBLIC, chat.HandleChatSearchJS)
	Route(mux, "/chat/chat_left_sidebar.js", TOTALLY_PUBLIC, chat.HandleChatLeftSidebarJS)
	Route(mux, "/chat/chat_add_topic.js", TOTALLY_PUBLIC, chat.HandleChatAddTopicJS)
	Route(mux, "/chat/chat_drag_to_pin.js", TOTALLY_PUBLIC, chat.HandleChatDragToPinJS)
	Route(mux, "/chat/chat_right_sidebar.js", TOTALLY_PUBLIC, chat.HandleChatRightSidebarJS)
	Route(mux, "/chat/chat_compose.js", TOTALLY_PUBLIC, chat.HandleChatComposeJS)
	Route(mux, "/chat/chat_help.js", TOTALLY_PUBLIC, chat.HandleChatHelpJS)
	Route(mux, "/chat/message.js", TOTALLY_PUBLIC, chat.HandleMessageJS)
	Route(mux, "/chat/message_view.js", TOTALLY_PUBLIC, chat.HandleMessageViewJS)
	Route(mux, "/chat/nav_stack.js", TOTALLY_PUBLIC, chat.HandleNavStackJS)
	Route(mux, "/chat/middle_pane.js", TOTALLY_PUBLIC, chat.HandleMiddlePaneJS)
	Route(mux, "/chat/chat_image_popup.js", TOTALLY_PUBLIC, chat.HandleChatImagePopupJS)
	Route(mux, "/chat/chat_code_popup.js", TOTALLY_PUBLIC, chat.HandleChatCodePopupJS)
	Route(mux, "/chat/notify.js", TOTALLY_PUBLIC, chat.HandleNotifyJS)
	Route(mux, "/chat/docs.js", TOTALLY_PUBLIC, chat.HandleDocsJS)

	// /learn — tutorial page (top-level, unauthed).
	Route(mux, "/learn", TOTALLY_PUBLIC, learn.HandleLearn)
	Route(mux, "/learn/learn.js", TOTALLY_PUBLIC, learn.HandleLearnJS)
	Route(mux, "/learn/callback_log.js", TOTALLY_PUBLIC, learn.HandleCallbackLogJS)
	Route(mux, "/learn/fake_host.js", TOTALLY_PUBLIC, learn.HandleFakeHostJS)
	Route(mux, "/learn/source/{file}", TOTALLY_PUBLIC, learn.HandleLearnSource)

	// Admin overview (filesystem stats). 404 for non-admins.
	Route(mux, "/admin", ADMIN_ONLY, admin.HandleAdmin)
	Route(mux, "/admin/", ADMIN_ONLY, admin.HandleAdmin)

	// /images/<file> — shared brand assets (avatars etc).
	Route(mux, "/images/{file}", TOTALLY_PUBLIC, platform.HandleImage)
}
