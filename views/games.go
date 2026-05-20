package views

import (
	"fmt"
	"html"
	"net/http"
	"time"
)

// HandleHome serves the site root "/": the Lyn Rummy launch-pad
// (play a game, solve puzzles, resume recent sessions). The Elm
// client owns its own sessions on disk.
func HandleHome(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	user := CurrentUser(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Lyn Rummy", user)
	PageSubtitle(w, "Jump straight into a game or browse your recent sessions.")

	renderGamesHero(w)
	renderRecentSessions(w, user)

	PageFooter(w)
}

// renderGamesHero: tiles for the full game and the puzzles surface.
func renderGamesHero(w http.ResponseWriter) {
	fmt.Fprint(w, `<style>
.games-hero { margin:20px 0 28px; display:grid; grid-template-columns:1fr 1fr; gap:20px; }
@media (max-width: 640px) { .games-hero { grid-template-columns:1fr; } }
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
    <h2>Game</h2>
    <p>Two-player rummy with a real referee. Drag cards from your hand to the board, build runs and sets, hit Complete Turn when you're happy with your play.</p>
    <div class="cta">
      <a class="play-btn" href="/game">Play a game →</a>
    </div>
  </div>
  <div class="games-tile">
    <h2>Puzzles</h2>
    <p>A single board, mid-game. Drag stacks to merge or split your way to a clean meld layout. Solo, no opponent — undo is free, and Replay walks back through your moves.</p>
    <div class="cta">
      <a class="play-btn" href="/puzzles">Solve puzzles →</a>
    </div>
  </div>
</div>`)
}

// renderRecentSessions lists the player's 10 most recent sessions.
// Each links to /game/N so the URL is reload-safe.
func renderRecentSessions(w http.ResponseWriter, user string) {
	ids, err := ListSessionIDs(user)
	if err != nil {
		return
	}
	// Newest first, cap at 10.
	for i, j := 0, len(ids)-1; i < j; i, j = i+1, j-1 {
		ids[i], ids[j] = ids[j], ids[i]
	}
	if len(ids) > 10 {
		ids = ids[:10]
	}

	eastern, _ := time.LoadLocation("America/New_York")

	fmt.Fprint(w, `<div class="sessions-section">
<h3>Recent sessions</h3>
<table class="sessions-table">
<tr><th>#</th><th>Created</th><th>Label</th><th class="n">Actions</th><th></th></tr>`)
	if len(ids) == 0 {
		fmt.Fprint(w, `<tr><td colspan="5" class="muted">No sessions yet — click Play a game above to start one.</td></tr>`)
	}
	for _, id := range ids {
		meta, _ := ReadSessionMeta(user, id)
		count, _ := CountSessionActions(user, id)
		ts := ""
		if t := SessionCreatedAt(meta); t > 0 {
			ts = time.Unix(t, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		}
		labelCell := SessionLabel(meta)
		if labelCell == "" {
			labelCell = `<span class="muted">—</span>`
		} else {
			labelCell = html.EscapeString(labelCell)
		}
		fmt.Fprintf(w,
			`<tr><td>%d</td><td>%s</td><td>%s</td><td class="n">%d</td>`+
				`<td><a href="/game/%d">Resume →</a></td></tr>`,
			id, html.EscapeString(ts), labelCell, count, id,
		)
	}
	fmt.Fprint(w, `</table></div>`)
}
