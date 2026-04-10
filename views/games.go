package views

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"time"
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
	PageHeader(w, "Games")

	rows, err := DB.Query(`
		SELECT g.id, g.player1_id, g.player2_id, g.created_at, g.puzzle_name,
			u1.full_name,
			u2.full_name,
			(SELECT COUNT(*) FROM game_events WHERE game_id = g.id) AS event_count
		FROM games g
		JOIN users u1 ON g.player1_id = u1.id
		LEFT JOIN users u2 ON g.player2_id = u2.id
		WHERE g.player1_id = ? OR g.player2_id = ?
			OR (g.player2_id IS NULL AND g.player1_id != ?)
		ORDER BY g.created_at DESC`,
		userID, userID, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load games.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Game</th><th>Player 1</th><th>Player 2</th><th>Events</th><th>Created</th></tr></thead><tbody>`)
	hasGames := false
	for rows.Next() {
		hasGames = true
		var id, p1ID, eventCount int
		var p2ID sql.NullInt64
		var createdAt int64
		var puzzleName sql.NullString
		var p1Name string
		var p2Name sql.NullString
		rows.Scan(&id, &p1ID, &p2ID, &createdAt, &puzzleName, &p1Name, &p2Name, &eventCount)

		label := fmt.Sprintf("Game #%d", id)
		if puzzleName.Valid && puzzleName.String != "" {
			label = puzzleName.String
		}

		p2Display := `<span class="muted">open — waiting for player</span>`
		if p2ID.Valid && p2Name.Valid {
			p2Display = UserLink(int(p2ID.Int64), p2Name.String)
		}

		t := time.Unix(createdAt, 0).Format("Jan 2 15:04")
		fmt.Fprintf(w, `<tr><td><a href="/gopher/game-lobby?id=%d">%s</a></td><td>%s</td><td>%s</td><td>%d</td><td>%s</td></tr>`,
			id, html.EscapeString(label), UserLink(p1ID, p1Name), p2Display, eventCount, t)
	}
	fmt.Fprint(w, `</tbody></table>`)
	if !hasGames {
		fmt.Fprint(w, `<p class="muted">No games yet.</p>`)
	}

	// Create game form.
	fmt.Fprint(w, `<h2>Create Game</h2>
<form method="POST" action="/gopher/game-lobby">
<label style="display:block;margin-bottom:4px;font-weight:bold">Puzzle name (optional)</label>
<input type="text" name="puzzle_name" placeholder="e.g. puzzle_24" style="width:200px;padding:4px;margin-bottom:8px"><br>
<button type="submit">Create</button>
</form>`)

	PageFooter(w)
}

func renderGameDetail(w http.ResponseWriter, userID, gameID int) {
	var p1ID int
	var p2ID sql.NullInt64
	var createdAt int64
	var puzzleName sql.NullString
	err := DB.QueryRow(`SELECT player1_id, player2_id, created_at, puzzle_name FROM games WHERE id = ?`,
		gameID).Scan(&p1ID, &p2ID, &createdAt, &puzzleName)
	if err != nil {
		http.Error(w, "Game not found", http.StatusNotFound)
		return
	}

	var p1Name string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, p1ID).Scan(&p1Name)

	label := fmt.Sprintf("Game #%d", gameID)
	if puzzleName.Valid && puzzleName.String != "" {
		label = puzzleName.String
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, label)

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

	// Event log.
	fmt.Fprint(w, `<h2>Event Log</h2>`)
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
	fmt.Fprint(w, `<table><thead><tr><th>#</th><th>Player</th><th>Payload</th><th>Time</th></tr></thead><tbody>`)
	for rows.Next() {
		var evID, evUserID int
		var evName, payload string
		var evTime int64
		rows.Scan(&evID, &evUserID, &evName, &payload, &evTime)
		et := time.Unix(evTime, 0).Format("15:04:05")
		// Truncate long payloads for display.
		display := payload
		if len(display) > 80 {
			display = display[:77] + "..."
		}
		fmt.Fprintf(w, `<tr><td>%d</td><td>%s</td><td><code>%s</code></td><td>%s</td></tr>`,
			evID, UserLink(evUserID, evName), html.EscapeString(display), et)
		eventCount++
	}
	fmt.Fprint(w, `</tbody></table>`)
	if eventCount == 0 {
		fmt.Fprint(w, `<p class="muted">No events yet.</p>`)
	}

	PageFooter(w)
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
