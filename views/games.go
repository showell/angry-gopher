package views

import (
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
	"sort"
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
	user := web.CurrentUser(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	web.PageHeader(w, "Lyn Rummy", user)
	web.PageSubtitle(w, "Jump straight into a game or browse your recent sessions.")

	renderGamesHero(w)
	renderChatLink(w)
	renderRecentSessions(w, user.ID)

	web.PageFooter(w)
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

// renderChatLink is the small entry point to the chat surface.
func renderChatLink(w http.ResponseWriter) {
	fmt.Fprint(w, `<p style="margin:0 0 24px;font-size:15px">`+
		`💬 <a href="/chat" style="font-weight:bold">Messages</a> `+
		`<span class="muted" style="font-size:13px">— private notes to other players</span></p>`)
}

// renderRecentSessions lists the 10 most recent full-game sessions
// across ALL players (any player may see others' games), newest
// first, with a Player column. The Resume link shows only on the
// viewer's own rows — the per-user routing can't open someone else's
// session.
func renderRecentSessions(w http.ResponseWriter, viewer string) {
	type sessionRow struct {
		player  string
		id      int64
		created int64
		label   string
		actions int
	}
	var rows []sessionRow
	for _, p := range web.ListUserIDs() {
		ids, err := ListSessionIDs(p)
		if err != nil {
			continue
		}
		for _, id := range ids {
			meta, _ := ReadSessionMeta(p, id)
			count, _ := CountSessionActions(p, id)
			rows = append(rows, sessionRow{
				player:  p,
				id:      id,
				created: SessionCreatedAt(meta),
				label:   SessionLabel(meta),
				actions: count,
			})
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].created > rows[j].created })
	if len(rows) > 10 {
		rows = rows[:10]
	}

	eastern, _ := time.LoadLocation("America/New_York")

	fmt.Fprint(w, `<div class="sessions-section">
<h3>Recent sessions</h3>
<table class="sessions-table">
<tr><th>Player</th><th>#</th><th>Created</th><th>Label</th><th class="n">Actions</th><th></th></tr>`)
	if len(rows) == 0 {
		fmt.Fprint(w, `<tr><td colspan="6" class="muted">No sessions yet — click Play a game above to start one.</td></tr>`)
	}
	for _, row := range rows {
		ts := ""
		if row.created > 0 {
			ts = time.Unix(row.created, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		}
		labelCell := row.label
		if labelCell == "" {
			labelCell = `<span class="muted">—</span>`
		} else {
			labelCell = html.EscapeString(labelCell)
		}
		resumeCell := `<span class="muted">—</span>`
		if row.player == viewer {
			resumeCell = fmt.Sprintf(`<a href="/game/%d">Resume →</a>`, row.id)
		}
		fmt.Fprintf(w,
			`<tr><td>%s</td><td>%d</td><td>%s</td><td>%s</td><td class="n">%d</td><td>%s</td></tr>`,
			html.EscapeString(web.GetUserName(row.player)), row.id, html.EscapeString(ts), labelCell, row.actions, resumeCell,
		)
	}
	fmt.Fprint(w, `</table></div>`)
}
