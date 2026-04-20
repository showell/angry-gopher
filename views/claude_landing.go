// Claude sub-landing. Pointer out to the claude-collab repo,
// where the collaboration patterns and the essay format live.
package views

import (
	"fmt"
	"net/http"
)

func HandleClaudeLanding(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/gopher/claude" && r.URL.Path != "/gopher/claude/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, "Claude", "claude")
	PageSubtitle(w, "Claude-Steve collaboration patterns and the essay format live in their own repo now.")
	fmt.Fprint(w, `<div class="cards">
  <div class="card">
    <h2><a href="http://localhost:9100">Local essay server</a></h2>
    <p>Read the essays with inline paragraph-anchored comments.
    Requires <code>claude-collab</code>'s Go server running on
    port 9100; see the README for build + run instructions.</p>
    <ul>
      <li><a href="http://localhost:9100/essays">Essay index</a></li>
    </ul>
  </div>
  <div class="card">
    <h2><a href="https://github.com/showell/claude-collab">GitHub</a></h2>
    <p>Browse on GitHub if the local server isn't running, or to share a link.</p>
    <ul>
      <li><a href="https://github.com/showell/claude-collab">README</a></li>
      <li><a href="https://github.com/showell/claude-collab/tree/master/essays">essays/</a></li>
      <li><a href="https://github.com/showell/claude-collab/blob/master/CONVENTIONS.md">CONVENTIONS.md</a></li>
    </ul>
  </div>
</div>`)
	PageFooter(w)
}
