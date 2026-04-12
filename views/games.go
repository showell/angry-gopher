package views

import (
	"database/sql"
	"encoding/json"
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
	replay := r.URL.Query().Get("replay")
	if idStr != "" && replay == "1" {
		id, _ := strconv.Atoi(idStr)
		renderGameReplay(w, userID, id)
	} else if idStr != "" {
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
	fmt.Fprintf(w, `<h2>Event Log</h2>
<p><a href="/gopher/game-lobby?id=%d&replay=1"><button>Replay Game</button></a></p>`, gameID)

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

// --- Game replay ---

func renderGameReplay(w http.ResponseWriter, userID, gameID int) {
	var p1Name string
	var p2Name sql.NullString
	err := DB.QueryRow(`
		SELECT u1.full_name, u2.full_name
		FROM games g
		JOIN users u1 ON g.player1_id = u1.id
		LEFT JOIN users u2 ON g.player2_id = u2.id
		WHERE g.id = ?`, gameID).Scan(&p1Name, &p2Name)
	if err != nil {
		http.Error(w, "Game not found", http.StatusNotFound)
		return
	}

	p2 := "Player 2"
	if p2Name.Valid {
		p2 = p2Name.String
	}

	rows, err := DB.Query(`
		SELECT ge.user_id, ge.payload FROM game_events ge
		WHERE ge.game_id = ? ORDER BY ge.id ASC`, gameID)
	if err != nil {
		http.Error(w, "Failed to load events", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type eventWithUser struct {
		UserID  int             `json:"user_id"`
		Payload json.RawMessage `json:"payload"`
	}
	var events []eventWithUser
	for rows.Next() {
		var e eventWithUser
		var p string
		rows.Scan(&e.UserID, &p)
		e.Payload = json.RawMessage(p)
		events = append(events, e)
	}

	eventsJSON, _ := json.Marshal(events)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("Replay: %s vs %s", p1Name, p2))

	fmt.Fprintf(w, `<a class="back" href="/gopher/game-lobby?id=%d">&larr; Back to game</a>`, gameID)

	fmt.Fprint(w, `
<div id="controls" style="margin:16px 0;display:flex;align-items:center;gap:8px">
  <button id="btn-prev" onclick="prev()" title="Left arrow">&#9664;</button>
  <button id="btn-play" onclick="toggleAutoplay()">&#9654; Play</button>
  <button id="btn-next" onclick="next()" title="Right arrow">&#9654;</button>
  <input id="speed" type="range" min="1" max="10" value="5" style="width:80px" title="Speed">
  <span id="step-label" style="font-weight:bold;font-size:14px"></span>
</div>
<div style="display:flex;gap:16px">
  <div>
    <canvas id="board" width="800" height="600" style="border:1px solid #ccc;background:#f8f8f0;border-radius:4px"></canvas>
  </div>
  <div id="sidebar" style="min-width:180px;font-size:13px">
    <div id="turn-info" style="margin-bottom:12px"></div>
    <div id="board-info" style="margin-bottom:12px"></div>
    <h3 style="color:#000080;margin:0 0 4px">Moves</h3>
    <div id="move-list" style="max-height:400px;overflow-y:auto"></div>
  </div>
</div>
`)

	fmt.Fprintf(w, `<script>
const EVENTS = %s;
const P1_NAME = %q;
const P2_NAME = %q;

// --- Constants ---
const CW = 27, CH = 40, PITCH = 33;
const VN = {1:"A",2:"2",3:"3",4:"4",5:"5",6:"6",7:"7",8:"8",9:"9",10:"T",11:"J",12:"Q",13:"K"};
const SN = {0:"\u2663",1:"\u2666",2:"\u2660",3:"\u2665"};
const SC = {0:"#1a1a1a",1:"#cc0000",2:"#1a1a1a",3:"#cc0000"};

function cl(c) { return VN[c.value] + SN[c.suit]; }

// --- Board logic ---
function stacksMatch(a, b) {
    if (a.board_cards.length !== b.board_cards.length) return false;
    for (let i = 0; i < a.board_cards.length; i++) {
        const ca = a.board_cards[i].card, cb = b.board_cards[i].card;
        if (ca.value !== cb.value || ca.suit !== cb.suit || ca.origin_deck !== cb.origin_deck) return false;
    }
    return a.loc.top === b.loc.top && a.loc.left === b.loc.left;
}

function applyMove(board, payload) {
    const ge = payload.json_game_event;
    if (!ge || ge.type !== 2 || !ge.player_action) return board;
    const be = ge.player_action.board_event;
    let result = [], rem = [...be.stacks_to_remove];
    for (const s of board) {
        const idx = rem.findIndex(r => stacksMatch(s, r));
        if (idx >= 0) rem.splice(idx, 1);
        else result.push(s);
    }
    return [...result, ...be.stacks_to_add];
}

// --- Steps ---
let steps = [];
let currentStep = 0;
let autoplayTimer = null;

function describePayload(payload) {
    if (payload.game_setup) return { desc: "Deal", type: "setup" };
    const ge = payload.json_game_event;
    if (!ge) return { desc: "?", type: "unknown" };
    if (ge.type === 0) return { desc: "Next turn", type: "advance" };
    if (ge.type === 1) return { desc: "End turn", type: "complete" };
    if (ge.type === 3) return { desc: "Undo", type: "undo" };
    if (ge.type === 2 && ge.player_action) {
        const hand = ge.player_action.hand_cards_to_release || [];
        const be = ge.player_action.board_event;
        const nr = be.stacks_to_remove.length, na = be.stacks_to_add.length;
        if (hand.length > 0) {
            const cards = hand.map(h => cl(h.card)).join(" ");
            if (nr === 0) return { desc: "Place " + cards, type: "place" };
            return { desc: "Play " + cards, type: "play" };
        }
        if (nr === 1 && na === 2) return { desc: "Split", type: "split" };
        if (nr === 2 && na === 1) return { desc: "Merge", type: "merge" };
        if (nr > 1 && na > 1) return { desc: "Tidy board", type: "tidy" };
        if (nr === 1 && na === 1) return { desc: "Move stack", type: "move" };
        return { desc: "Rearrange", type: "rearrange" };
    }
    return { desc: "Action", type: "action" };
}

function buildSteps() {
    steps = [];
    if (EVENTS.length === 0) return;
    const first = EVENTS[0].payload;
    if (!first.game_setup) return;

    let board = first.game_setup.board.map(s => ({board_cards: s.board_cards, loc: s.loc}));
    let turn = 1;
    let turnPlayer = P1_NAME;

    steps.push({
        board: JSON.parse(JSON.stringify(board)),
        desc: "Initial board",
        type: "setup",
        turn, turnPlayer,
        handCards: [],
    });

    for (let i = 1; i < EVENTS.length; i++) {
        const ev = EVENTS[i];
        const payload = ev.payload;
        const info = describePayload(payload);

        board = applyMove(board, payload);

        // Track hand cards played.
        let handCards = [];
        if (payload.json_game_event && payload.json_game_event.player_action) {
            const hcr = payload.json_game_event.player_action.hand_cards_to_release || [];
            handCards = hcr.map(h => h.card);
        }

        if (info.type === "advance") {
            turn++;
            turnPlayer = (turn %% 2 === 1) ? P1_NAME : P2_NAME;
        }

        steps.push({
            board: JSON.parse(JSON.stringify(board)),
            desc: info.desc,
            type: info.type,
            turn, turnPlayer,
            handCards,
        });
    }
}

// --- Rendering ---
const canvas = document.getElementById("board");
const ctx = canvas.getContext("2d");

function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arcTo(x + w, y, x + w, y + r, r);
    ctx.lineTo(x + w, y + h - r);
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    ctx.lineTo(x + r, y + h);
    ctx.arcTo(x, y + h, x, y + h - r, r);
    ctx.lineTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
    ctx.closePath();
}

function drawCard(x, y, card, fresh, highlighted) {
    const label = cl(card);
    const color = SC[card.suit];

    // Shadow.
    ctx.fillStyle = "rgba(0,0,0,0.08)";
    roundRect(x + 1, y + 1, CW, CH, 3);
    ctx.fill();

    // Card body.
    ctx.fillStyle = highlighted ? "#fff3b0" : (fresh ? "#fffff0" : "white");
    roundRect(x, y, CW, CH, 3);
    ctx.fill();

    // Border.
    ctx.strokeStyle = highlighted ? "#e6a800" : "#aaa";
    ctx.lineWidth = highlighted ? 1.5 : 0.8;
    roundRect(x, y, CW, CH, 3);
    ctx.stroke();

    // Text.
    ctx.fillStyle = color;
    ctx.font = "bold 11px 'Courier New', monospace";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x + CW / 2, y + CH / 2);
}

function drawBoard(step) {
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Find newly added cards (in stacks_to_add but not stacks_to_remove).
    const newCards = new Set();
    for (const c of step.handCards) {
        newCards.add(c.value + "," + c.suit + "," + c.origin_deck);
    }

    for (const stack of step.board) {
        for (let i = 0; i < stack.board_cards.length; i++) {
            const bc = stack.board_cards[i];
            const x = stack.loc.left + i * PITCH;
            const y = stack.loc.top;
            const key = bc.card.value + "," + bc.card.suit + "," + bc.card.origin_deck;
            const highlighted = newCards.has(key);
            drawCard(x, y, bc.card, bc.state === 1, highlighted);
        }
    }
}

// --- Sidebar ---
function updateSidebar(step) {
    document.getElementById("turn-info").innerHTML =
        "<b>Turn " + step.turn + "</b> — " + step.turnPlayer + "'s turn";
    document.getElementById("board-info").innerHTML =
        step.board.length + " stacks, " +
        step.board.reduce((n, s) => n + s.board_cards.length, 0) + " cards on board";
}

function updateMoveList() {
    const el = document.getElementById("move-list");
    let html = "";
    let lastTurn = 0;
    for (let i = 0; i < steps.length; i++) {
        const s = steps[i];
        if (s.turn !== lastTurn) {
            html += "<div style='margin-top:8px;font-weight:bold;color:#000080'>Turn " + s.turn + " — " + s.turnPlayer + "</div>";
            lastTurn = s.turn;
        }
        const active = i === currentStep;
        const style = active
            ? "background:#e0e0ff;padding:2px 4px;border-radius:3px;cursor:pointer"
            : "padding:2px 4px;cursor:pointer";
        const icon = s.type === "place" || s.type === "play" ? "\u2660 "
            : s.type === "complete" ? "\u2714 "
            : s.type === "advance" ? "\u27a1 "
            : s.type === "tidy" ? "\u2728 "
            : s.type === "split" ? "\u2702 "
            : "";
        html += "<div style='" + style + "' onclick='goTo(" + i + ")'>" + icon + s.desc + "</div>";
    }
    el.innerHTML = html;

    // Scroll active into view.
    const activeEl = el.querySelector("[style*='background:#e0e0ff']");
    if (activeEl) activeEl.scrollIntoView({ block: "nearest" });
}

// --- Controls ---
function render() {
    const step = steps[currentStep];
    drawBoard(step);
    updateSidebar(step);
    updateMoveList();
    document.getElementById("step-label").textContent =
        (currentStep) + " / " + (steps.length - 1) + ": " + step.desc;
    document.getElementById("btn-prev").disabled = currentStep === 0;
    document.getElementById("btn-next").disabled = currentStep === steps.length - 1;
}

function next() {
    if (currentStep < steps.length - 1) { currentStep++; render(); }
    else stopAutoplay();
}
function prev() {
    if (currentStep > 0) { currentStep--; render(); }
}
function goTo(i) {
    currentStep = i; render(); stopAutoplay();
}

function toggleAutoplay() {
    if (autoplayTimer) { stopAutoplay(); return; }
    document.getElementById("btn-play").textContent = "\u23F8 Pause";
    function tick() {
        const speed = document.getElementById("speed").value;
        const ms = 1200 - speed * 100;
        if (currentStep < steps.length - 1) {
            currentStep++; render();
            autoplayTimer = setTimeout(tick, ms);
        } else {
            stopAutoplay();
        }
    }
    tick();
}

function stopAutoplay() {
    if (autoplayTimer) { clearTimeout(autoplayTimer); autoplayTimer = null; }
    document.getElementById("btn-play").textContent = "\u25B6 Play";
}

document.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") { next(); e.preventDefault(); }
    if (e.key === "ArrowLeft") { prev(); e.preventDefault(); }
    if (e.key === " ") { toggleAutoplay(); e.preventDefault(); }
});

buildSteps();
render();
</script>`, string(eventsJSON), p1Name, p2)

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
