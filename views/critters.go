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
	"strconv"
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
	"cows":      true,
	"mice":      true,
	"sort_cats": true,
}

// buggyStudies: playable but known-broken. Portal shows a visible
// [BUGGY] tag so nobody gets surprised. Clear this entry once the
// feature is fixed.
var buggyStudies = map[string]string{
	"sort_cats": "orange/grey cats visually ambiguous; sorted cats still draggable; drop behavior unreliable",
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
	case sub == "sessions":
		crittersSessionsList(w)
	case strings.HasPrefix(sub, "sessions/"):
		crittersSessionDetail(w, strings.TrimPrefix(sub, "sessions/"))
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
<nav><a href="/gopher/">← Gopher home</a> &nbsp;·&nbsp; <a href="/gopher/critters/sessions">Recorded sessions</a></nav>
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
			if note, buggy := buggyStudies[s.Name]; buggy {
				fmt.Fprintf(w, ` <span style="color:#c1440e;font-weight:bold">[BUGGY]</span> <span class="muted">— %s</span>`,
					html.EscapeString(note))
			}
		} else {
			fmt.Fprint(w, `<span class="muted">DSL defined; engine not yet implemented</span>`)
		}
		// Per-study code & docs cross-links.
		fmt.Fprintf(w, ` <span class="muted"> · <a href="/gopher/wiki/gopher/critters/studies/%s.claude">DSL</a></span>`,
			html.EscapeString(s.Name))
		fmt.Fprint(w, `</div>`)
	}

	// Code & Docs section — findability knob = 10.
	fmt.Fprint(w, `
<h2>Code &amp; Docs</h2>
<ul>
<li><b>Gopher side:</b>
  <a href="/gopher/wiki/gopher/critters/critters.go">critters/critters.go</a> ·
  <a href="/gopher/wiki/gopher/critters/critters.claude">sidecar</a> ·
  <a href="/gopher/wiki/gopher/views/critters.go">views/critters.go</a> ·
  <a href="/gopher/wiki/gopher/views/critters.claude">sidecar</a>
</li>
<li><b>Study DSLs:</b>
  <a href="/gopher/wiki/gopher/tree/critters/studies">critters/studies/</a>
</li>
<li><b>Elm engine:</b>
  <a href="/gopher/wiki/elm-critters/">elm-critters repo</a> ·
  <a href="/gopher/wiki/elm-critters/README.md">README</a> ·
  <a href="/gopher/wiki/elm-critters/src/Main.elm">Main.elm</a>
</li>
<li><b>Schema:</b>
  <a href="/gopher/wiki/gopher/schema/schema.go">schema.go</a>
  (critter_sessions table)
</li>
<li><b>Live data:</b>
  <a href="/gopher/critters/sessions">Recorded sessions</a>
</li>
</ul>
</body></html>`)
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
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
  .app-nav { padding: 8px 16px; background: #000080; color: white; font-size: 13px; }
  .app-nav a { color: white; text-decoration: none; margin-right: 14px; }
  .app-nav a:hover { text-decoration: underline; }
  .app-main { padding: 20px; }
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
<div class="app-nav">
  <a href="/gopher/">← Gopher home</a>
  <a href="/gopher/critters/">Critter studies</a>
  <a href="/gopher/wiki/elm-critters/">elm-critters source</a>
  <a href="/gopher/wiki/gopher/critters/studies/%s.claude">%s.claude (DSL)</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/gopher/critters/elm.js"></script>
<script>
var app = Elm.Main.init({
  node: document.getElementById("root"),
  flags: {
    seed: Math.floor(Math.random() * 2147483647),
    study: %q
  }
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
</div>
</body></html>
`, html.EscapeString(title), study, study, study, study)
}

// crittersSessionsList lists recent recorded sessions.
func crittersSessionsList(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	rows, err := DB.Query(`
		SELECT id, study, label, saved_at, length(payload)
		FROM critter_sessions
		ORDER BY id DESC
		LIMIT 100`)
	if err != nil {
		http.Error(w, "query failed", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Critter Sessions</title>
<style>
body { font-family: sans-serif; margin: 40px auto; max-width: 900px; padding: 0 24px; }
h1 { color: #000080; }
table { border-collapse: collapse; width: 100%; margin-top: 12px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
a { color: #000080; }
nav { font-size: 13px; margin-bottom: 16px; }
</style>
</head><body>
<nav><a href="/gopher/">← Gopher home</a> &nbsp;·&nbsp; <a href="/gopher/critters/">Studies</a> &nbsp;·&nbsp; <a href="/gopher/wiki/">Wiki</a></nav>
<h1>Recorded sessions</h1>
<table><thead><tr><th>ID</th><th>Study</th><th>Label</th><th>Saved at</th><th>Bytes</th></tr></thead><tbody>`)
	count := 0
	for rows.Next() {
		var id, bytes int
		var study, label, savedAt string
		if err := rows.Scan(&id, &study, &label, &savedAt, &bytes); err != nil {
			continue
		}
		fmt.Fprintf(w, `<tr><td><a href="/gopher/critters/sessions/%d">%d</a></td><td>%s</td><td>%s</td><td>%s</td><td>%d</td></tr>`,
			id, id, html.EscapeString(study), html.EscapeString(label),
			html.EscapeString(savedAt), bytes)
		count++
	}
	fmt.Fprint(w, `</tbody></table>`)
	if count == 0 {
		fmt.Fprint(w, `<p><em>No sessions yet. Play a study from the <a href="/gopher/critters/">studies page</a>.</em></p>`)
	}
	fmt.Fprint(w, `</body></html>`)
}

// crittersSessionDetail shows the raw payload for one session.
func crittersSessionDetail(w http.ResponseWriter, idStr string) {
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	var study, label, savedAt, payload string
	err = DB.QueryRow(
		`SELECT study, label, saved_at, payload FROM critter_sessions WHERE id = ?`, id,
	).Scan(&study, &label, &savedAt, &payload)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>Session %d — %s</title>
<style>
body { font-family: sans-serif; margin: 40px auto; max-width: 1100px; padding: 0 24px; }
h1 { color: #000080; }
dt { font-weight: bold; color: #555; }
dd { margin: 4px 0 10px 0; }
pre { background: #f8f8f4; border: 1px solid #ddd; padding: 12px; overflow-x: auto;
      font-size: 12px; line-height: 1.4; white-space: pre-wrap; word-break: break-word; }
nav { font-size: 13px; margin-bottom: 16px; }
nav a { color: #000080; }
</style>
</head><body>
<nav><a href="/gopher/">← Gopher home</a> &nbsp;·&nbsp; <a href="/gopher/critters/sessions">Sessions</a> &nbsp;·&nbsp; <a href="/gopher/critters/">Studies</a></nav>
<h1>Session %d</h1>
<dl>
<dt>Study</dt><dd>%s</dd>
<dt>Label</dt><dd>%s</dd>
<dt>Saved at</dt><dd>%s</dd>
</dl>
<h2>Payload</h2>
<pre>%s</pre>
</body></html>`, id, html.EscapeString(study), id,
		html.EscapeString(study), html.EscapeString(label),
		html.EscapeString(savedAt), html.EscapeString(payload))
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
