package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
	"net/url"
)

// chatChromeTop emits the chat-subsystem top bar: a small Home link, the
// page/conversation title, the Chat/Docs/Recent/Images/Code/Settings
// sub-nav, and identity + (admin) + log out on the right. active is
// "chat" | "docs" | "recent" | "images" | "code" | "settings" | ""
// (a conversation — the link is deliberately not highlighted once
// you're inside one).
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
	// PRODUCT_DECISION: the theme toggle is a placeholder glyph until
	// chat_theme.js paints the right icon (sun/moon) for the current
	// data-theme. The button is part of the chrome — its WIRING (click
	// to flip) and palette live JS-side (colors.js, chat_theme.js).
	fmt.Fprintf(w,
		`<header class="app-top chat-top"><div class="chat-top-left">`+
			`<a class="chat-top-home" href="/">Home</a>`+
			`<span class="chat-top-title">%s</span>`+
			`<span class="chat-top-links">%s · %s · %s · %s · %s · %s</span></div>`+
			`<div class="app-top-user">`+
			`<button id="chat-theme-toggle" type="button" title="Toggle theme" aria-label="Toggle theme" `+
			`style="background:none;border:none;cursor:pointer;font-size:16px;padding:0 8px;vertical-align:middle">🌙</button> · `+
			`<strong>%s</strong>%s · <a href="/learn">Learn</a> · <a href="/logout">Log out</a></div></header>`,
		html.EscapeString(title),
		navLink("/chat", "Chat", "chat"),
		navLink("/chat/docs", "Docs", "docs"),
		navLink("/chat/recent", "Recent", "recent"),
		navLink("/chat/images", "Images", "images"),
		navLink("/chat/code", "Code", "code"),
		navLink("/settings", "Settings", "settings"),
		html.EscapeString(user.Name), adminLink)
}

// chatPageHeader writes the page with the chat-subsystem top bar (Home +
// title + Chat/Docs/Settings + identity) and opens the body WITHOUT an
// <h1> — the title lives in the bar. active is "chat" | "docs" |
// "settings" | "".
func chatPageHeader(w http.ResponseWriter, title string, user users.User, active string) {
	web.PageHeadAndStyle(w, chatTabTitle(active))
	// PRODUCT_DECISION: colors.js loads synchronously BEFORE the chrome
	// HTML — install() reads localStorage, sets data-theme on <html>,
	// and injects the palette <style> block. Chrome HTML then renders
	// with the right colors first-paint (no flash). chat_theme.js wires
	// the toggle button (emitted by chatChromeTop) and can defer until
	// later since the button is just a visual decoration until clicked.
	v := url.QueryEscape(web.AssetVersion)
	fmt.Fprintf(w,
		`<script src="/chat/colors.js?v=%s"></script>`+
			`<script>ChatColors.install();</script>`+
			`<script defer src="/chat/chat_theme.js?v=%s"></script>`,
		v, v)
	chatChromeTop(w, user, title, active)
	fmt.Fprint(w, `<div class="app-body-wrap">`)
}

// StylesJSPath is the embedded shared transcript-styles client.
var StylesJSPath = "chat/styles.js"

// HandleStylesJS serves chat/styles.js (ChatStyles namespace shared by
// /chat/code and /chat/images).
func HandleStylesJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, StylesJSPath, "styles.js missing from the binary")
}

// ColorsJSPath / ChatThemeJSPath are the palette + theme-toggle clients.
var ColorsJSPath = "chat/colors.js"
var ChatThemeJSPath = "chat/chat_theme.js"

// HandleColorsJS serves chat/colors.js (ChatColors namespace: palette
// + install + toggle, every chat-subsystem page loads it early).
func HandleColorsJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ColorsJSPath, "colors.js missing from the binary")
}

// HandleChatThemeJS serves chat/chat_theme.js (wires the toggle button).
func HandleChatThemeJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ChatThemeJSPath, "chat_theme.js missing from the binary")
}

// chatTabTitle picks the browser-tab text from which chat-subsystem page
// you're on. Mirrors the nav: "Docs"/"Recent"/"Settings" for those,
// "Chat" for the conversation page (active="") and the people list
// (active="chat").
func chatTabTitle(active string) string {
	switch active {
	case "docs":
		return "Docs"
	case "recent":
		return "Recent"
	case "images":
		return "Images"
	case "code":
		return "Code"
	case "settings":
		return "Settings"
	}
	return "Chat"
}
