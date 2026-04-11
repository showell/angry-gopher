package views

import (
	"fmt"
	"net/http"
)

// HandleTour serves /gopher/tour — a full-page tour showing every
// CRUD page in an iframe layout. Great for demos and screenshots.
func HandleTour(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Tour — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 0; padding: 20px; background: #f4f4f4; }
h1 { color: #000080; text-align: center; }
p { text-align: center; color: #666; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(600px, 1fr)); gap: 20px; padding: 20px; }
.card { background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); overflow: hidden; }
.card-header { background: #000080; color: white; padding: 8px 16px; font-weight: bold; }
.card-header a { color: white; text-decoration: none; }
.card-header a:hover { text-decoration: underline; }
iframe { width: 100%; height: 400px; border: none; }
</style>
</head><body>
<h1>🐹 Angry Gopher Tour</h1>
<p>Every page in one view. Click a title to open it full-size.</p>
<div class="grid">`)

	for _, page := range GetPages() {
		fmt.Fprintf(w, `<div class="card">
<div class="card-header"><a href="%s">%s</a></div>
<iframe src="%s" loading="lazy"></iframe>
</div>`, page.Path, page.Title, page.Path)
	}

	fmt.Fprint(w, `</div></body></html>`)
}
