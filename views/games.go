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
	PageHeader(w, "Games")
	PageSubtitle(w, "Play LynRummy and other games with your team — right inside your chat app.")

	rows, err := DB.Query(`
		SELECT g.id, g.player1_id, g.player2_id, g.created_at, g.puzzle_name, g.label,
			u1.full_name,
			u2.full_name,
			(SELECT COUNT(*) FROM game_events WHERE game_id = g.id) AS event_count
		FROM games g
		JOIN users u1 ON g.player1_id = u1.id
		LEFT JOIN users u2 ON g.player2_id = u2.id
		WHERE g.archived = 0 AND (g.player1_id = ? OR g.player2_id = ?
			OR (g.player2_id IS NULL AND g.player1_id != ?))
		ORDER BY g.created_at DESC`,
		userID, userID, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load games.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>#</th><th>Label</th><th>Puzzle</th><th>Player 1</th><th>Player 2</th><th>Events</th><th>Created</th></tr></thead><tbody>`)
	hasGames := false
	for rows.Next() {
		hasGames = true
		var id, p1ID, eventCount int
		var p2ID sql.NullInt64
		var createdAt int64
		var puzzleName sql.NullString
		var label string
		var p1Name string
		var p2Name sql.NullString
		rows.Scan(&id, &p1ID, &p2ID, &createdAt, &puzzleName, &label, &p1Name, &p2Name, &eventCount)

		labelCell := `<span class="muted">—</span>`
		if label != "" {
			labelCell = html.EscapeString(label)
		}
		puzzleCell := `<span class="muted">—</span>`
		if puzzleName.Valid && puzzleName.String != "" {
			puzzleCell = html.EscapeString(puzzleName.String)
		}

		p2Display := `<span class="muted">open — waiting for player</span>`
		if p2ID.Valid && p2Name.Valid {
			p2Display = UserLink(int(p2ID.Int64), p2Name.String)
		}

		t := time.Unix(createdAt, 0).Format("Jan 2 15:04")
		fmt.Fprintf(w, `<tr><td><a href="/gopher/game-lobby?id=%d">%d</a></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%d</td><td>%s</td></tr>`,
			id, id, labelCell, puzzleCell, UserLink(p1ID, p1Name), p2Display, eventCount, t)
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
	PageHeader(w, heading)

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
