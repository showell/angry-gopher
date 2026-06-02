// Package learn serves /learn — an aspiring-developer tutorial that walks
// through how chat was built. Top-level (outside /chat) and unauthed, so
// anyone can read it; the page itself is a near-empty HTML shell that
// learn.js fills in via createElement + .style.X. The "slowly eliminate
// CSS" project starts here: this package emits no <style> blocks beyond
// the borrowed image-popup rules its demo needs.
package learn

import (
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
	"net/url"
)

// HandleLearn serves /learn. Minimal head + an empty <div id="learn-root">;
// learn.js builds the chrome, sections, spoilers, and demo. We deliberately
// skip web.PageHeadAndStyle so the page doesn't inherit the shared
// stylesheet — the experiment is to grow the page in JS-styles only.
func HandleLearn(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/learn" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>%s</title>`, html.EscapeString("Learn — Lyn Rummy"))
	// PRODUCT_DECISION: both popups own their own styles inline now —
	// /learn loads no external CSS for them.
	fmt.Fprint(w, `</head><body><div id="learn-root"></div>`)
	v := url.QueryEscape(web.AssetVersion)
	fmt.Fprintf(w,
		`<script src="/chat/chat_image_popup.js?v=%s"></script>`+
			`<script src="/chat/chat_code_popup.js?v=%s"></script>`+
			`<script src="/chat/message.js?v=%s"></script>`+
			`<script src="/chat/message_view.js?v=%s"></script>`+
			`<script src="/chat/nav_stack.js?v=%s"></script>`+
			`<script src="/chat/middle_pane.js?v=%s"></script>`+
			`<script src="/chat/chat_right_sidebar.js?v=%s"></script>`+
			`<script src="/chat/chat_compose.js?v=%s"></script>`+
			`<script src="/chat/chat_add_topic.js?v=%s"></script>`+
			`<script src="/chat/chat_drag_to_pin.js?v=%s"></script>`+
			`<script src="/learn/callback_log.js?v=%s"></script>`+
			`<script src="/learn/fake_host.js?v=%s"></script>`+
			`<script src="/learn/learn.js?v=%s"></script>`,
		v, v, v, v, v, v, v, v, v, v, v, v, v)
	fmt.Fprint(w, `</body></html>`)
}

// HandleLearnJS serves the Learn-page client.
func HandleLearnJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, "learn/learn.js", "learn.js missing from the binary")
}

// HandleCallbackLogJS serves the shared callback-log widget used by
// most lesson demos. Demo code, not part of the real chat system —
// but built the same way (one factory, owned DOM + styles).
func HandleCallbackLogJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, "learn/callback_log.js", "callback_log.js missing from the binary")
}

// HandleFakeHostJS serves the shared fetch-mocking facility every
// host-interacting demo registers routes with. One global wrap,
// routes register their match + respond, fall through to real fetch
// for any URL no route claims.
func HandleFakeHostJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, "learn/fake_host.js", "fake_host.js missing from the binary")
}

// learnSourceAllowlist names every module the Learn page is allowed to
// reveal. Adding a lesson means adding the source file here AND wiring it
// into learn.js — the explicit allowlist keeps the source endpoint from
// accidentally exposing anything we didn't curate.
var learnSourceAllowlist = map[string]string{
	"chat_image_popup.js":   "chat/chat_image_popup.js",
	"chat_code_popup.js":    "chat/chat_code_popup.js",
	"message.js":            "chat/message.js",
	"message_view.js":       "chat/message_view.js",
	"nav_stack.js":          "chat/nav_stack.js",
	"middle_pane.js":        "chat/middle_pane.js",
	"chat_right_sidebar.js": "chat/chat_right_sidebar.js",
	"chat_compose.js":       "chat/chat_compose.js",
	"chat_add_topic.js":     "chat/chat_add_topic.js",
	"chat_drag_to_pin.js":   "chat/chat_drag_to_pin.js",
	"callback_log.js":       "learn/callback_log.js",
	"fake_host.js":          "learn/fake_host.js",
}

// HandleLearnSource serves the raw text of an allowlisted JS module so the
// spoiler widget can show real, deployed source (never drifts). 404 for
// anything not in the allowlist.
func HandleLearnSource(w http.ResponseWriter, r *http.Request) {
	file := r.PathValue("file")
	path, ok := learnSourceAllowlist[file]
	if !ok {
		http.NotFound(w, r)
		return
	}
	data, err := web.ReadAsset(path)
	if err != nil {
		http.Error(w, "asset missing: "+file, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write(data)
}
