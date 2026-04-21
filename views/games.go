package views

import (
	"fmt"
	"html"
	"net/http"
	"time"
)

// HandleGames serves /gopher/game-lobby. Minimal launch-pad for
// the playable Elm LynRummy client. No legacy game-event
// system; the Elm client owns its own sessions via
// lynrummy_elm_sessions.
func HandleGames(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, "Games", "games")
	PageSubtitle(w, "Jump straight into a LynRummy game or browse your recent sessions.")

	renderGamesHero(w)
	renderRecentSessions(w)

	PageFooter(w)
}

// renderGamesHero: single-tile hero for LynRummy (the only
// playable game). Critter studies were ripped 2026-04-20.
func renderGamesHero(w http.ResponseWriter) {
	fmt.Fprint(w, `<style>
.games-hero { margin:20px 0 28px; }
.games-tile { border:1px solid #ccc; border-radius:8px; padding:22px; background:#fcfcf8;
              display:flex; flex-direction:column; }
.games-tile h2 { margin:0 0 6px; font-size:22px; color:#000080; }
.games-tile p { color:#444; margin:0 0 16px; font-size:14px; line-height:1.5; }
.games-tile .cta { margin-top:auto; }
.play-btn { display:inline-block; background:#000080; color:white; padding:12px 28px;
            border-radius:6px; text-decoration:none; font-weight:bold; font-size:16px; }
.play-btn:hover { background:#0000a0; }
.sessions-section { margin-top:28px; }
.sessions-section h3 { color:#000080; margin:0 0 10px; font-size:18px; }
.sessions-table { width:100%; border-collapse:collapse; font-size:14px; }
.sessions-table th, .sessions-table td { text-align:left; padding:8px 10px; border-bottom:1px solid #eee; }
.sessions-table th { background:#f4f4ec; font-weight:bold; }
.sessions-table tr:hover { background:#fafaf6; }
.sessions-table a { color:#000080; text-decoration:none; font-weight:bold; }
.sessions-table a:hover { text-decoration:underline; }
.sessions-table .n { text-align:right; font-variant-numeric:tabular-nums; }
.sessions-table .muted { color:#888; }
</style>
<div class="games-hero">
  <div class="games-tile">
    <h2>LynRummy</h2>
    <p>Two-player rummy with a real referee. Drag cards from your hand to the board, build runs and sets, hit Complete Turn when you're happy with your play.</p>
    <div class="cta"><a class="play-btn" href="/gopher/lynrummy-elm/">Play LynRummy →</a></div>
  </div>
</div>`)
}

// renderRecentSessions lists the 10 most recent Elm LynRummy
// sessions. Each links to /gopher/lynrummy-elm/play/N — the
// server renders the Elm client with session N baked into the
// init flag, so the URL is reload-safe.
func renderRecentSessions(w http.ResponseWriter) {
	rows, err := DB.Query(`
		SELECT s.id, s.created_at, s.label,
		       (SELECT COUNT(*) FROM lynrummy_elm_actions WHERE session_id = s.id) AS n
		FROM lynrummy_elm_sessions s
		ORDER BY s.id DESC
		LIMIT 10`)
	if err != nil {
		return
	}
	defer rows.Close()

	eastern, _ := time.LoadLocation("America/New_York")

	fmt.Fprint(w, `<div class="sessions-section">
<h3>Recent sessions</h3>
<table class="sessions-table">
<tr><th>#</th><th>Created</th><th>Label</th><th class="n">Actions</th><th></th></tr>`)
	any := false
	for rows.Next() {
		any = true
		var id, createdAt int64
		var n int
		var label string
		if err := rows.Scan(&id, &createdAt, &label, &n); err != nil {
			continue
		}
		ts := time.Unix(createdAt, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		labelCell := label
		if labelCell == "" {
			labelCell = `<span class="muted">—</span>`
		} else {
			labelCell = html.EscapeString(labelCell)
		}
		fmt.Fprintf(w,
			`<tr><td>%d</td><td>%s</td><td>%s</td><td class="n">%d</td>`+
				`<td><a href="/gopher/lynrummy-elm/play/%d">Resume →</a></td></tr>`,
			id, html.EscapeString(ts), labelCell, n, id,
		)
	}
	if !any {
		fmt.Fprint(w, `<tr><td colspan="5" class="muted">No sessions yet — click Play LynRummy above to start one.</td></tr>`)
	}
	fmt.Fprint(w, `</table></div>`)
}
