package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
)

// chatChromeTop emits the chat-subsystem top bar: a small Home link, the
// page/conversation title, the People/Docs/Settings sub-nav, and identity
// + (admin) + log out on the right. In chat there's no "Lyn Rummy"
// branding — the small Home link is the only way back to the top-level
// home. active is "people" | "docs" | "settings" | "" (a conversation).
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
		navLink("/chat", "People", "people"),
		navLink("/chat/docs", "Docs", "docs"),
		navLink("/settings", "Settings", "settings"),
		html.EscapeString(user.Name), adminLink)
}

// chatPageHeader writes the page with the chat-subsystem top bar (Home +
// title + People/Docs/Settings + identity) and opens the body WITHOUT an
// <h1> — the title lives in the bar. active is "people" | "docs" |
// "settings" | "".
func chatPageHeader(w http.ResponseWriter, title string, user users.User, active string) {
	web.PageHeadAndStyle(w)
	chatChromeTop(w, user, title, active)
	fmt.Fprint(w, `<div class="app-body-wrap">`)
}
