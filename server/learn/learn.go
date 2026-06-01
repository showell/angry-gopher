// Package learn serves /learn — an aspiring-developer tutorial that walks
// through how chat was built. Top-level (outside /chat) and unauthed, so
// anyone can read it; the page itself is a near-empty HTML shell that
// learn.js fills in via createElement + .style.X. The "slowly eliminate
// CSS" project starts here: this package emits no <style> blocks beyond
// the borrowed image-popup rules its demo needs.
package learn

import (
	"angry-gopher/server/chat"
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
	// PRODUCT_DECISION: the popup demo needs ImagePopupCSS to render right.
	// This is the one CSS dependency the page borrows; eliminating it is
	// the next step (migrate chat_image_popup.js to inline-styles itself).
	fmt.Fprint(w, chat.ImagePopupCSS)
	fmt.Fprint(w, `</head><body><div id="learn-root"></div>`)
	fmt.Fprintf(w,
		`<script src="/chat/chat_image_popup.js?v=%s"></script>`+
			`<script src="/learn/learn.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion))
	fmt.Fprint(w, `</body></html>`)
}

// HandleLearnJS serves the Learn-page client.
func HandleLearnJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, "learn/learn.js", "learn.js missing from the binary")
}

// learnSourceAllowlist names every module the Learn page is allowed to
// reveal. Adding a lesson means adding the source file here AND wiring it
// into learn.js — the explicit allowlist keeps the source endpoint from
// accidentally exposing anything we didn't curate.
var learnSourceAllowlist = map[string]string{
	"images.js": "chat/images.js",
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
