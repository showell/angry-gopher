// Package driving serves /driving — a standalone first-person driving toy
// (browser canvas, TypeScript bundled to one IIFE by ops/build_driving).
// Top-level and unauthed, like /learn: anyone can play, there's no user
// state. The page is a near-empty HTML shell; app.js builds its own canvas
// and overlays in JS, so the server emits no markup or CSS beyond the
// title and the one <script> — consistent with the "no CSS from Go"
// direction the /learn page started.
package driving

import (
	"angry-gopher/server/platform"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"strings"
)

// appJSPath is the embedded bundle (see embed.go), produced by ops/build_driving.
const appJSPath = "games/driving/app.js"

// HandleDriving dispatches /driving/*: the page itself and the one JS bundle.
// The switch is the route table (mirrors lynrummy.HandleGame's shape).
func HandleDriving(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/driving")
	sub = strings.TrimPrefix(sub, "/")
	switch sub {
	case "", "/":
		drivingPage(w)
	case "app.js":
		platform.ServeJS(w, appJSPath, "app.js not found — run `ops/build_driving`")
	default:
		http.NotFound(w, r)
	}
}

// drivingPage serves /driving: a minimal shell that loads app.js, which builds
// the whole DOM itself. AssetVersion is the ?v= cache-buster (same as /learn).
func drivingPage(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	v := url.QueryEscape(platform.AssetVersion)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">`+
		`<meta name="viewport" content="width=device-width, initial-scale=1">`+
		`<title>%s</title></head><body>`+
		`<script src="/driving/app.js?v=%s"></script>`+
		`</body></html>`, html.EscapeString("Driving"), v)
}
