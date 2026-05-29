package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
)

// chatChromeTop emits the chat-subsystem top bar: a small Home link, the
// page/conversation title, the Chat/Docs/Settings sub-nav, and identity +
// (admin) + log out on the right. In chat there's no "Lyn Rummy"
// branding — the small Home link is the only way back to the top-level
// home. active is "chat" | "docs" | "settings" | "" (a conversation —
// the link is deliberately not highlighted once you're inside one).
func chatChromeTop(w http.ResponseWriter, user users.User, title, active string) {
	navLink := func(href, label, key string) string {
		if active == key {
			return fmt.Sprintf(`<strong>%s</strong>`, label)
		}
		return fmt.Sprintf(`<a href="%s">%s</a>`, href, label)
	}
	adminLink := ""
	if user.Admin {
		adminLink = ` · <a href="/admin">Admin</a>`
	}
	fmt.Fprintf(w,
		`<header class="app-top chat-top"><div class="chat-top-left">`+
			`<a class="chat-top-home" href="/">Home</a>`+
			`<span class="chat-top-title">%s</span>`+
			`<span class="chat-top-links">%s · %s · %s</span></div>`+
			`<div class="app-top-user"><strong>%s</strong>%s · <a href="/logout">Log out</a></div></header>`,
		html.EscapeString(title),
		navLink("/chat", "Chat", "chat"),
		navLink("/chat/docs", "Docs", "docs"),
		navLink("/settings", "Settings", "settings"),
		html.EscapeString(user.Name), adminLink)
}

// chatPageHeader writes the page with the chat-subsystem top bar (Home +
// title + Chat/Docs/Settings + identity) and opens the body WITHOUT an
// <h1> — the title lives in the bar. active is "chat" | "docs" |
// "settings" | "".
func chatPageHeader(w http.ResponseWriter, title string, user users.User, active string) {
	web.PageHeadAndStyle(w, chatTabTitle(active))
	chatChromeTop(w, user, title, active)
	fmt.Fprint(w, `<div class="app-body-wrap">`)
}

// chatTabTitle picks the browser-tab text from which chat-subsystem page
// you're on. Mirrors the nav: "Docs"/"Settings" for those, "Chat" for the
// conversation page (active="") and the people list (active="chat").
func chatTabTitle(active string) string {
	switch active {
	case "docs":
		return "Docs"
	case "settings":
		return "Settings"
	}
	return "Chat"
}
