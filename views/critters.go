// Critter-studies views: study list + launch page + elm.js proxy.
// The Elm engine lives in ~/showell_repos/elm-critters; Gopher serves
// its compiled elm.js through this view.
package views

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"angry-gopher/critters"
)

// CritterStudiesDir is where study DSLs live. Set by main.
var CritterStudiesDir = "critters/studies"

// ElmCrittersDir is the sibling repo containing compiled elm.js.
// Set by main / env; defaults to the standard location.
var ElmCrittersDir = filepath.Join(os.Getenv("HOME"), "showell_repos/elm-critters")

// playableStudies are studies that the current Elm engine actually
// implements. The DSL files for other studies exist but haven't
// been compiled into playable code yet.
var playableStudies = map[string]bool{
	"cows": true,
}

// HandleCritters dispatches /gopher/critters/*.
func HandleCritters(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/critters/")
	sub = strings.TrimPrefix(sub, "/gopher/critters")
	switch {
	case sub == "" || sub == "/":
		crittersList(w)
	case sub == "play" || strings.HasPrefix(sub, "play/"):
		crittersPlay(w, strings.TrimPrefix(strings.TrimPrefix(sub, "play"), "/"))
	case sub == "elm.js":
		crittersElmJS(w, r)
	case sub == "save_recording":
		critters.HandleSaveRecording(w, r)
	default:
		http.NotFound(w, r)
	}
}

func crittersList(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	studies := critters.LoadStudies(CritterStudiesDir)
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Critter Studies — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 60px auto; max-width: 780px; padding: 0 24px; }
h1 { color: #000080; }
h2 { color: #000080; margin-top: 24px; }
.study { border: 1px solid #ccc; border-radius: 6px; padding: 16px; margin: 12px 0;
         background: #fcfcf8; }
.study h3 { margin: 0 0 4px; }
.study p { color: #555; margin: 0 0 10px; font-size: 14px; }
.study a { color: #000080; font-weight: bold; text-decoration: none; }
.study a:hover { text-decoration: underline; }
.muted { color: #999; font-weight: normal; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
</style>
</head><body>
<nav><a href="/gopher/">← Gopher home</a></nav>
<h1>Critter Studies</h1>
<p>General-purpose critter-study engine. Each study is a small
drag-and-drop browser game that records behavioral telemetry back
to Gopher.</p>
`)
	for _, s := range studies {
		fmt.Fprintf(w, `<div class="study"><h3>%s</h3><p>%s</p>`,
			html.EscapeString(s.Title), html.EscapeString(s.Desc))
		if playableStudies[s.Name] {
			fmt.Fprintf(w, `<a href="/gopher/critters/play/%s">Play ▶</a>`,
				html.EscapeString(s.Name))
		} else {
			fmt.Fprint(w, `<span class="muted">DSL defined; engine not yet implemented</span>`)
		}
		fmt.Fprint(w, `</div>`)
	}
	fmt.Fprint(w, `</body></html>`)
}

// crittersPlay serves the Elm-loading page for a given study.
// V1: the current Elm engine is hardcoded to the cow study, so any
// playable study loads the same page. Future: pass the study name
// as a flag so one engine covers multiple studies.
func crittersPlay(w http.ResponseWriter, study string) {
	if study != "" && !playableStudies[study] {
		http.Error(w, "Study not yet playable: "+study, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	title := study
	if title == "" {
		title = "critter study"
	}
	fmt.Fprintf(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>%s</title>
<style>
  body { margin: 20px; font-family: sans-serif; background: #f4f4ec; }
  @keyframes wobble {
    0%%   { transform: translate(0, 0); }
    20%%  { transform: translate(-8px, 4px); }
    40%%  { transform: translate(6px, -5px); }
    60%%  { transform: translate(-5px, -3px); }
    80%%  { transform: translate(4px, 6px); }
    100%% { transform: translate(0, 0); }
  }
  .wobble { animation: wobble 0.4s; }
</style>
</head><body>
<div id="root"></div>
<script src="/gopher/critters/elm.js"></script>
<script>
var app = Elm.Main.init({
  node: document.getElementById("root"),
  flags: Math.floor(Math.random() * 2147483647)
});
app.ports.saveRecording.subscribe(function (payload) {
  payload.saved_at = new Date().toISOString();
  payload.study = %q;
  fetch("/gopher/critters/save_recording", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(function (r) {
      if (r.ok) { console.log("[saved]", payload.label); }
      else { console.warn("[save failed status=" + r.status + "]", payload); }
    })
    .catch(function (e) {
      console.warn("[save failed: " + e.message + "] payload follows:");
      console.log(JSON.stringify(payload));
    });
});
</script>
</body></html>
`, html.EscapeString(title), study)
}

// crittersElmJS serves the compiled elm.js from the elm-critters repo.
// Simple file proxy; no caching in V1.
func crittersElmJS(w http.ResponseWriter, r *http.Request) {
	path := filepath.Join(ElmCrittersDir, "elm.js")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "elm.js not found — run `elm make` in "+ElmCrittersDir, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}
