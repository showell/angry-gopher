// Claude sub-landing. One stop above the individual Claude-owned
// tools (Issues, DMs). Linked from the Claude card on the home page.
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
	PageSubtitle(w, "Talk to Claude, see what he's working on, file new issues.")
	fmt.Fprint(w, `<div class="cards">
  <div class="card">
    <h2><a href="/gopher/claude-issues">Issues</a></h2>
    <p>File requests and bug reports. Each issue gets a dedicated detail page with status + plan + log.</p>
    <ul>
      <li><a href="/gopher/claude-issues">Active + recently shipped</a></li>
    </ul>
  </div>
  <div class="card">
    <h2><a href="/gopher/dm?user_id=2">DM Claude</a></h2>
    <p>Direct message thread. Long-form and threaded replies; live SSE updates when Claude posts.</p>
    <ul>
      <li><a href="/gopher/dm?user_id=2">Open conversation</a></li>
    </ul>
  </div>
</div>`)
	PageFooter(w)
}
