package views

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"time"

	"angry-gopher/auth"
)

// HandleGames serves /gopher/game-lobby.
//
//   No params:     list your games + open games
//   ?id=N:         game detail (players, event log)
//   POST:          create a game
func HandleGames(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		if r.URL.Query().Get("label") == "1" {
			handleLabel(w, r, userID)
			return
		}
		if r.URL.Query().Get("rename") == "1" {
			handleRename(w, r, userID)
			return
		}
		handleGamePost(w, r, userID)
		return
	}

	idStr := r.URL.Query().Get("id")
	if idStr != "" {
		id, _ := strconv.Atoi(idStr)
		renderGameDetail(w, userID, id)
	} else {
		renderGameList(w, userID)
	}
}

func renderGameList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, "Games", "games")
	PageSubtitle(w, "Pick your poison. Two-player rummy with a real referee, or drag-critter behavior studies.")

	renderGamesHero(w, userID)

	// Create game form — tucked under a disclosure below the hero.
	fmt.Fprint(w, `<details style="margin-top:16px"><summary style="cursor:pointer;font-weight:bold;color:#000080">➕ Create a new LynRummy game</summary>
<form method="POST" action="/gopher/game-lobby" style="margin-top:8px">
<label style="display:block;margin-bottom:4px;font-weight:bold">Puzzle name (optional)</label>
<input type="text" name="puzzle_name" placeholder="e.g. puzzle_24" style="width:200px;padding:4px;margin-bottom:8px"><br>
<button type="submit">Create</button>
</form></details>`)

	PageFooter(w)
}

// renderGamesHero is the Games landing's single-row hero: three tiles
// side-by-side on wide screens (LynRummy promise, Critters promise,
// your active LynRummy games). Collapses to stacked on narrow screens.
// Visuals are randomized each pageload so it doesn't feel static.
func renderGamesHero(w http.ResponseWriter, userID int) {
	fmt.Fprint(w, `<style>
.games-hero { display:grid; grid-template-columns: 1fr 1fr minmax(280px, 1.1fr); gap:20px; margin:20px 0 28px; }
@media (max-width: 1100px) { .games-hero { grid-template-columns: 1fr 1fr; } }
@media (max-width: 720px) { .games-hero { grid-template-columns: 1fr; } }
.games-tile { border:1px solid #ccc; border-radius:8px; padding:18px; background:#fcfcf8;
              display:flex; flex-direction:column; }
.games-tile h2 { margin:0 0 4px; font-size:20px; }
.games-tile h2 a { color:#000080; text-decoration:none; }
.games-tile h2 a:hover { text-decoration:underline; }
.games-tile p { color:#444; margin:0 0 12px; font-size:13px; line-height:1.4; }
.games-tile .stage { flex:1; display:flex; align-items:center; justify-content:center;
                     min-height:140px; background:#f4f4f0; border-radius:6px; margin:4px 0 12px; padding:12px; }
.playing-card { display:inline-block; width:56px; height:78px; border:1px solid #888;
                border-radius:5px; background:white; position:relative; margin:0 -8px;
                box-shadow:0 1px 3px rgba(0,0,0,.15); font-family:serif;
                transform-origin:bottom center; }
.playing-card.red { color:#c00; }
.playing-card.black { color:#111; }
.playing-card .rank { position:absolute; top:4px; left:6px; font-size:14px; font-weight:bold; }
.playing-card .suit-big { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%);
                          font-size:28px; }
.playing-card .rank-br { position:absolute; bottom:4px; right:6px; font-size:14px; font-weight:bold;
                         transform:rotate(180deg); }
.critter { font-size:48px; margin:0 6px; display:inline-block; }
.critter.floaty { animation: critter-float 3s ease-in-out infinite; }
@keyframes critter-float { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-6px); } }
.games-tile .cta { margin-top:auto; }
.games-tile .cta a { display:inline-block; background:#000080; color:white; padding:6px 14px;
                     border-radius:4px; text-decoration:none; font-weight:bold; font-size:13px; }
.games-tile .cta a:hover { background:#0000a0; }
.games-active-list { list-style:none; padding:0; margin:0; font-size:13px;
                     max-height:160px; overflow-y:auto; }
.games-active-list li { padding:4px 6px; border-bottom:1px dashed #ddd; }
.games-active-list li:last-child { border-bottom:none; }
.games-active-list a { color:#000080; font-weight:bold; text-decoration:none; }
.games-active-list a:hover { text-decoration:underline; }
.games-active-list .row-meta { color:#888; font-size:11px; }
</style>
<div class="games-hero">
  <div class="games-tile">
    <h2><a href="#lynrummy-active">LynRummy</a></h2>
    <p>Two-player rummy variant. Drag cards, build runs and sets, let the referee catch mistakes.</p>
    <div class="stage">`)
	// Render a fanned hand of 5 cards with a small random tilt.
	fmt.Fprint(w, randomHandHTML(5))
	fmt.Fprint(w, `</div>
    <div class="cta"><a href="#lynrummy-active">Active games ↓</a></div>
  </div>
  <div class="games-tile">
    <h2><a href="/gopher/critters/">Critter studies</a></h2>
    <p>Drag-and-drop behavioral games. Sort mice, group ducks, whatever the study calls for.</p>
    <div class="stage">`)
	fmt.Fprint(w, randomCrittersHTML(4))
	fmt.Fprint(w, `</div>
    <div class="cta"><a href="/gopher/critters/">Open portal →</a></div>
  </div>
  <div class="games-tile">
    <h2>Your active games</h2>
    <p>LynRummy — click through to open or spectate.</p>`)
	renderActiveGamesList(w, userID)
	fmt.Fprint(w, `
  </div>
</div>`)
}

// renderActiveGamesList emits a compact list for the Games-landing
// third column. One line per game: #, label/puzzle, opponent, event
// count. Full detail still lives on /gopher/game-lobby?id=N.
func renderActiveGamesList(w http.ResponseWriter, userID int) {
	rows, err := DB.Query(`
		SELECT g.id, g.player1_id, g.player2_id, g.puzzle_name, g.label,
			u1.full_name, u2.full_name,
			(SELECT COUNT(*) FROM game_events WHERE game_id = g.id) AS event_count
		FROM games g
		JOIN users u1 ON g.player1_id = u1.id
		LEFT JOIN users u2 ON g.player2_id = u2.id
		WHERE g.archived = 0 AND (g.player1_id = ? OR g.player2_id = ?
			OR (g.player2_id IS NULL AND g.player1_id != ?))
		ORDER BY g.created_at DESC
		LIMIT 20`,
		userID, userID, userID)
	if err != nil {
		fmt.Fprint(w, `<p class="muted">Failed to load games.</p>`)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<ul class="games-active-list">`)
	hasGames := false
	for rows.Next() {
		hasGames = true
		var id, p1ID, eventCount int
		var p2ID sql.NullInt64
		var puzzleName sql.NullString
		var label, p1Name string
		var p2Name sql.NullString
		rows.Scan(&id, &p1ID, &p2ID, &puzzleName, &label, &p1Name, &p2Name, &eventCount)

		title := fmt.Sprintf("#%d", id)
		if label != "" {
			title = fmt.Sprintf("#%d — %s", id, label)
		} else if puzzleName.Valid && puzzleName.String != "" {
			title = fmt.Sprintf("#%d — %s", id, puzzleName.String)
		}

		var opponent string
		switch {
		case p1ID == userID && p2ID.Valid && p2Name.Valid:
			opponent = "vs " + p2Name.String
		case p1ID == userID:
			opponent = "waiting for player"
		case p2ID.Valid && int(p2ID.Int64) == userID:
			opponent = "vs " + p1Name
		default:
			opponent = "open — " + p1Name
		}
		fmt.Fprintf(w,
			`<li><a href="/gopher/game-lobby?id=%d">%s</a> <span class="row-meta">%s · %d events</span></li>`,
			id, html.EscapeString(title), html.EscapeString(opponent), eventCount,
		)
	}
	fmt.Fprint(w, `</ul>`)
	if !hasGames {
		fmt.Fprint(w, `<p class="muted" style="font-size:13px">No games yet — create one below.</p>`)
	}
}

func randomHandHTML(n int) string {
	suits := []struct {
		glyph string
		color string
	}{
		{"♠", "black"}, {"♥", "red"}, {"♦", "red"}, {"♣", "black"},
	}
	ranks := []string{"A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"}
	var b []byte
	baseTilt := -8
	for i := 0; i < n; i++ {
		s := suits[(int(time.Now().UnixNano())/((i+1)*131))%len(suits)]
		r := ranks[(int(time.Now().UnixNano())/((i+1)*419))%len(ranks)]
		tilt := baseTilt + (16*i)/(n-1+1)
		card := fmt.Sprintf(
			`<span class="playing-card %s" style="transform:rotate(%ddeg)"><span class="rank">%s%s</span><span class="suit-big">%s</span><span class="rank-br">%s%s</span></span>`,
			s.color, tilt, r, s.glyph, s.glyph, r, s.glyph,
		)
		b = append(b, card...)
	}
	return string(b)
}

func randomCrittersHTML(n int) string {
	pool := []string{"🐭", "🐁", "🐹", "🦆", "🐥", "🐰", "🐢", "🦀"}
	var b []byte
	for i := 0; i < n; i++ {
		em := pool[(int(time.Now().UnixNano())/((i+1)*97))%len(pool)]
		b = append(b, fmt.Sprintf(`<span class="critter floaty" style="animation-delay:%dms">%s</span>`, i*250, em)...)
	}
	return string(b)
}

func renderGameDetail(w http.ResponseWriter, userID, gameID int) {
	var p1ID int
	var p2ID sql.NullInt64
	var createdAt int64
	var puzzleName sql.NullString
	var label string
	err := DB.QueryRow(`SELECT player1_id, player2_id, created_at, puzzle_name, label FROM games WHERE id = ?`,
		gameID).Scan(&p1ID, &p2ID, &createdAt, &puzzleName, &label)
	if err != nil {
		http.Error(w, "Game not found", http.StatusNotFound)
		return
	}

	var p1Name string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, p1ID).Scan(&p1Name)

	heading := fmt.Sprintf("Game #%d", gameID)
	if label != "" {
		heading = fmt.Sprintf("Game #%d — %s", gameID, label)
	} else if puzzleName.Valid && puzzleName.String != "" {
		heading = puzzleName.String
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, heading, "games")

	fmt.Fprint(w, `<a class="back" href="/gopher/game-lobby">&larr; Back to games</a>`)

	t := time.Unix(createdAt, 0).Format("Jan 2 15:04")
	fmt.Fprintf(w, `<table>
<tr><td><b>Player 1</b></td><td>%s</td></tr>`, UserLink(p1ID, p1Name))

	if p2ID.Valid {
		var p2Name string
		DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, p2ID.Int64).Scan(&p2Name)
		fmt.Fprintf(w, `<tr><td><b>Player 2</b></td><td>%s</td></tr>`, UserLink(int(p2ID.Int64), p2Name))
	} else {
		fmt.Fprint(w, `<tr><td><b>Player 2</b></td><td class="muted">Waiting for player</td></tr>`)
	}
	fmt.Fprintf(w, `<tr><td><b>Created</b></td><td>%s</td></tr></table>`, t)

	// Label form — any owner can edit.
	isOwner := userID == p1ID || (p2ID.Valid && int(p2ID.Int64) == userID)
	if isOwner {
		fmt.Fprintf(w, `<h2>Label</h2>
<form method="POST" action="/gopher/game-lobby?id=%d&label=1" style="margin-bottom:16px">
<input type="text" name="label" value="%s" placeholder="e.g. Throwaway Game" style="width:240px;padding:4px">
<button type="submit">Save</button>
<span style="color:#888;font-size:12px;margin-left:8px">A human-memorable handle for this game. Leave blank to clear.</span>
</form>`, gameID, html.EscapeString(label))
	}

	// Puzzle-name rename form (admins only).
	if auth.IsAdmin(userID) {
		currentName := ""
		if puzzleName.Valid {
			currentName = puzzleName.String
		}
		fmt.Fprintf(w, `<h2>Rename (puzzle)</h2>
<form method="POST" action="/gopher/game-lobby?id=%d&rename=1" style="margin-bottom:16px">
<input type="text" name="puzzle_name" value="%s" placeholder="New puzzle name" style="width:240px;padding:4px">
<button type="submit">Save</button>
<span style="color:#888;font-size:12px;margin-left:8px">Leave blank to clear the puzzle name</span>
</form>`, gameID, html.EscapeString(currentName))
	}

	// Event log.
	fmt.Fprintf(w, `<h2>Event Log</h2>
<p><a href="/gopher/game-replay?id=%d"><button>Replay Game</button></a></p>`, gameID)

	rows, err := DB.Query(`
		SELECT ge.id, ge.user_id, u.full_name, ge.payload, ge.created_at
		FROM game_events ge
		JOIN users u ON ge.user_id = u.id
		WHERE ge.game_id = ?
		ORDER BY ge.id ASC`, gameID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load events.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	eventCount := 0
	fmt.Fprint(w, `<table><thead><tr><th>#</th><th>Player</th><th>Action</th><th>Time</th></tr></thead><tbody>`)
	for rows.Next() {
		var evID, evUserID int
		var evName, payload string
		var evTime int64
		rows.Scan(&evID, &evUserID, &evName, &payload, &evTime)
		et := time.Unix(evTime, 0).Format("15:04:05")
		desc := describeEvent(payload)
		fmt.Fprintf(w, `<tr><td>%d</td><td>%s</td><td>%s</td><td>%s</td></tr>`,
			evID, UserLink(evUserID, evName), desc, et)
		eventCount++
	}
	fmt.Fprint(w, `</tbody></table>`)
	if eventCount == 0 {
		fmt.Fprint(w, `<p class="muted">No events yet.</p>`)
	}

	PageFooter(w)
}

// --- Event description ---

var valueNames = map[int]string{
	1: "A", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7",
	8: "8", 9: "9", 10: "T", 11: "J", 12: "Q", 13: "K",
}
var suitNames = map[int]string{0: "C", 1: "D", 2: "S", 3: "H"}

func cardStr(c map[string]interface{}) string {
	v := int(c["value"].(float64))
	s := int(c["suit"].(float64))
	return valueNames[v] + suitNames[s]
}

func describeEvent(payload string) string {
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(payload), &data); err != nil {
		return html.EscapeString(payload[:min(len(payload), 60)])
	}

	if _, ok := data["game_setup"]; ok {
		return "Game setup (deal)"
	}

	ge, ok := data["json_game_event"].(map[string]interface{})
	if !ok {
		return html.EscapeString(payload[:min(len(payload), 60)])
	}

	eventType := int(ge["type"].(float64))
	switch eventType {
	case 0:
		return "Advance turn"
	case 1:
		return "Complete turn"
	case 3:
		return "Undo"
	case 2:
		// Player action — describe the move.
		pa, ok := ge["player_action"].(map[string]interface{})
		if !ok {
			return "Player action"
		}
		be, ok := pa["board_event"].(map[string]interface{})
		if !ok {
			return "Player action"
		}
		remove := be["stacks_to_remove"].([]interface{})
		add := be["stacks_to_add"].([]interface{})
		hand := pa["hand_cards_to_release"].([]interface{})

		if len(hand) > 0 {
			cards := ""
			for i, hc := range hand {
				if i > 0 {
					cards += " "
				}
				hcm := hc.(map[string]interface{})
				cards += cardStr(hcm["card"].(map[string]interface{}))
			}
			if len(remove) == 0 {
				return fmt.Sprintf("Place <b>%s</b> (new stack)", cards)
			}
			return fmt.Sprintf("Play <b>%s</b> from hand", cards)
		}

		if len(remove) == 1 && len(add) == 2 {
			return "Split stack"
		}
		if len(remove) == 2 && len(add) == 1 {
			return "Merge stacks"
		}
		if len(remove) > 0 && len(add) > 0 {
			return fmt.Sprintf("Rearrange (%d→%d)", len(remove), len(add))
		}
		return "Player action"
	}
	return html.EscapeString(payload[:min(len(payload), 60)])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}


func handleLabel(w http.ResponseWriter, r *http.Request, userID int) {
	idStr := r.URL.Query().Get("id")
	gameID, _ := strconv.Atoi(idStr)
	if gameID <= 0 {
		http.Error(w, "Invalid game id", http.StatusBadRequest)
		return
	}
	var p1ID int
	var p2ID sql.NullInt64
	if err := DB.QueryRow(`SELECT player1_id, player2_id FROM games WHERE id = ?`, gameID).Scan(&p1ID, &p2ID); err != nil {
		http.Error(w, "Game not found", http.StatusNotFound)
		return
	}
	isOwner := userID == p1ID || (p2ID.Valid && int(p2ID.Int64) == userID)
	if !isOwner {
		http.Error(w, "Only game participants can set the label", http.StatusForbidden)
		return
	}
	r.ParseForm()
	newLabel := r.FormValue("label")
	if _, err := DB.Exec(`UPDATE games SET label = ? WHERE id = ?`, newLabel, gameID); err != nil {
		http.Error(w, "Failed to label", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, fmt.Sprintf("/gopher/game-lobby?id=%d", gameID), http.StatusSeeOther)
}

func handleRename(w http.ResponseWriter, r *http.Request, userID int) {
	if !auth.IsAdmin(userID) {
		http.Error(w, "Admin only", http.StatusForbidden)
		return
	}
	idStr := r.URL.Query().Get("id")
	gameID, _ := strconv.Atoi(idStr)
	if gameID <= 0 {
		http.Error(w, "Invalid game id", http.StatusBadRequest)
		return
	}
	r.ParseForm()
	newName := r.FormValue("puzzle_name")
	var nameVal interface{}
	if newName != "" {
		nameVal = newName
	}
	_, err := DB.Exec(`UPDATE games SET puzzle_name = ? WHERE id = ?`, nameVal, gameID)
	if err != nil {
		http.Error(w, "Failed to rename", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, fmt.Sprintf("/gopher/game-lobby?id=%d", gameID), http.StatusSeeOther)
}

func handleGamePost(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	puzzleName := r.FormValue("puzzle_name")

	var puzzle interface{}
	if puzzleName != "" {
		puzzle = puzzleName
	}

	now := time.Now().Unix()
	result, err := DB.Exec(
		`INSERT INTO games (player1_id, player2_id, created_at, puzzle_name) VALUES (?, NULL, ?, ?)`,
		userID, now, puzzle)
	if err != nil {
		http.Error(w, "Failed to create game", http.StatusInternalServerError)
		return
	}

	gameID, _ := result.LastInsertId()
	http.Redirect(w, r, fmt.Sprintf("/gopher/game-lobby?id=%d", gameID), http.StatusSeeOther)
}
