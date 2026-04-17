// LynRummy Elm client view. Serves the compiled Elm app from
// games/lynrummy/elm-port-docs/ through Gopher. Standalone
// client in V1 — no server round-trip, no auth, no real
// game state. Just "Steve can reach the new client via the
// Gopher URL."
//
// label: SPIKE (lynrummy-elm-integration)
package views

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// ElmLynRummyDir is the repo-relative directory containing the
// Elm source + compiled elm.js. Set by main; default assumes
// Gopher runs from the angry-gopher repo root.
var ElmLynRummyDir = "games/lynrummy/elm-port-docs"

// HandleLynRummyElm dispatches /gopher/lynrummy-elm/*.
func HandleLynRummyElm(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/lynrummy-elm")
	sub = strings.TrimPrefix(sub, "/")
	switch sub {
	case "", "/":
		lynrummyElmPlay(w)
	case "elm.js":
		lynrummyElmJS(w)
	default:
		http.NotFound(w, r)
	}
}

func lynrummyElmPlay(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>LynRummy (Elm)</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
  .app-nav { padding: 8px 16px; background: #000080; color: white; font-size: 13px; }
  .app-nav a { color: white; text-decoration: none; margin-right: 14px; }
  .app-nav a:hover { text-decoration: underline; }
  .app-main { padding: 0; }
</style>
</head><body>
<div class="app-nav">
  <a href="/gopher/">← Gopher home</a>
  <a href="/gopher/game-lobby">Game lobby</a>
  <a href="/gopher/wiki/gopher/games/lynrummy/elm-port-docs/">Elm source</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/gopher/lynrummy-elm/elm.js"></script>
<script>
  Elm.Main.init({ node: document.getElementById("root") });
</script>
</div>
</body></html>`)
}

func lynrummyElmJS(w http.ResponseWriter) {
	path := filepath.Join(ElmLynRummyDir, "elm.js")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "elm.js not found — run `elm make src/Main.elm --output=elm.js` in "+ElmLynRummyDir, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}
