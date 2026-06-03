package home

import (
	"angry-gopher/server/users"
	"angry-gopher/server/platform"
	"fmt"
	"net/http"
)

// HandleHome serves the site root "/": the Lyn Rummy launch pad
// (play a game, solve puzzles). TOTALLY_PUBLIC — anon visitors get the
// same marketing surface; the Game/Puzzles tiles route through the
// login flow on click.
func HandleHome(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	user := users.CurrentUser(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	platform.PageHeader(w, "Lyn Rummy", user.Name, user.Admin)
	platform.PageSubtitle(w, "Jump straight into a game or browse the puzzles.")
	renderGamesHero(w)
	platform.PageFooter(w)
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
