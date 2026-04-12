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
		if r.URL.Query().Get("rename") == "1" {
			handleRename(w, r, userID)
			return
		}
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

	// Rename form (admins only).
	if auth.IsAdmin(userID) {
		currentName := ""
		if puzzleName.Valid {
			currentName = puzzleName.String
		}
		fmt.Fprintf(w, `<h2>Rename</h2>
<form method="POST" action="/gopher/game-lobby?id=%d&rename=1" style="margin-bottom:16px">
<input type="text" name="puzzle_name" value="%s" placeholder="New puzzle name" style="width:240px;padding:4px">
<button type="submit">Save</button>
<span style="color:#888;font-size:12px;margin-left:8px">Leave blank to clear the puzzle name</span>
</form>`, gameID, html.EscapeString(currentName))
	}

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
<style>
#replay-wrap { max-width: 1100px; }
#controls { margin:12px 0; display:flex; align-items:center; gap:8px; }
#controls button { min-width: 36px; }
#narration {
    background: #f0f0ff; border-left: 4px solid #000080; padding: 10px 14px;
    margin: 8px 0 12px; font-size: 15px; line-height: 1.5; min-height: 44px;
    border-radius: 0 4px 4px 0;
    display: flex; align-items: center; gap: 12px;
}
#narration img { width: 48px; height: 48px; border-radius: 50%%; flex-shrink: 0; }
#narration .text { flex: 1; }
#narration .player-name { font-weight: bold; color: #000080; }
#narration .card { font-weight: bold; }
#narration .card.red { color: #cc0000; }
#narration .card.black { color: #1a1a1a; }
#layout { display: flex; gap: 16px; align-items: flex-start; }
#move-list-wrap {
    min-width: 200px; max-width: 220px; font-size: 12px;
    max-height: 520px; overflow-y: auto; border: 1px solid #ddd;
    border-radius: 4px; padding: 4px;
}
.ml-turn { margin-top: 6px; font-weight: bold; color: #000080; font-size: 13px; padding: 2px 4px; }
.ml-item { padding: 3px 6px; cursor: pointer; border-radius: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ml-item:hover { background: #e8e8ff; }
.ml-item.active { background: #c0c0ff; font-weight: bold; }
.ml-type { display: inline-block; width: 16px; text-align: center; }
</style>
<div id="replay-wrap">
<div id="controls">
  <button id="btn-prev" onclick="prev()" title="Left arrow key">&#9664;</button>
  <button id="btn-play" onclick="toggleAutoplay()" title="Spacebar">&#9654; Play</button>
  <button id="btn-next" onclick="next()" title="Right arrow key">&#9654;</button>
  <input id="scrubber" type="range" min="0" max="1" value="0" style="flex:1;margin:0 8px" title="Scrub through game">
  <span id="step-label" style="font-weight:bold;font-size:14px;white-space:nowrap"></span>
</div>
<div id="narration"></div>
<div id="layout">
  <div style="flex:1">
    <canvas id="board" width="800" height="500" style="border:1px solid #ccc;background:#faf9f0;border-radius:6px"></canvas>
    <div id="hands" style="margin-top:10px;display:flex;gap:24px;flex-wrap:wrap"></div>
  </div>
  <div id="move-list-wrap"></div>
</div>
</div>
`)

	fmt.Fprintf(w, `<script>
const EVENTS = %s;
const P1_NAME = %q;
const P2_NAME = %q;

// --- Card display (matches Angry Cat rendering) ---
const CW = 32, CH = 46, PITCH = 38;
const VN = {1:"A",2:"2",3:"3",4:"4",5:"5",6:"6",7:"7",8:"8",9:"9",10:"10",11:"J",12:"Q",13:"K"};
const SN = {0:"\u2663",1:"\u2666",2:"\u2660",3:"\u2665"};
const SC = {0:"black",1:"red",2:"black",3:"red"};
const SL = {0:"C",1:"D",2:"S",3:"H"};

function cl(c) { return VN[c.value] + SN[c.suit]; }
function cardHTML(c) {
    const color = c.suit === 1 || c.suit === 3 ? "red" : "black";
    return '<span class="card ' + color + '">' + VN[c.value] + SN[c.suit] + '</span>';
}
function stackDesc(cards) {
    return cards.map(bc => cl(bc.card)).join(" ");
}

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

// --- Step building with compound event detection ---
let steps = [];
let currentStep = 0;
let autoplayTimer = null;

function classifyEvent(payload) {
    if (payload.game_setup) return { type: "setup", cards: [] };
    const ge = payload.json_game_event;
    if (!ge) return { type: "unknown", cards: [] };
    if (ge.type === 0) return { type: "advance", cards: [] };
    if (ge.type === 1) return { type: "complete", cards: [] };
    if (ge.type === 3) return { type: "undo", cards: [] };
    if (ge.type !== 2 || !ge.player_action) return { type: "unknown", cards: [] };

    const hand = ge.player_action.hand_cards_to_release || [];
    const be = ge.player_action.board_event;
    const nr = be.stacks_to_remove.length, na = be.stacks_to_add.length;
    const cards = hand.map(h => h.card);

    if (cards.length > 0 && nr === 0) return { type: "place", cards };
    if (cards.length > 0 && nr > 0) return { type: "play", cards };
    if (nr === 1 && na === 2) return { type: "split", cards };
    if (nr === 2 && na === 1) return { type: "merge", cards };
    if (nr > 1 && na > 1) return { type: "tidy", cards };
    if (nr === 1 && na === 1) return { type: "move", cards };
    return { type: "rearrange", cards };
}

// Look ahead from current step to detect compound moves.
// Returns a richer description if the next few steps form
// a recognizable pattern (split-extract-merge = "peel for set").
function detectCompound(stepIdx) {
    if (stepIdx >= steps.length) return null;
    const s = steps[stepIdx];

    // Split followed by merge with hand card = split-for-set or peel
    if (s.type === "split" && stepIdx + 1 < steps.length) {
        const s2 = steps[stepIdx + 1];
        if (s2.type === "merge" && s2.handCards.length > 0) {
            const cards = s2.handCards.map(c => cardHTML(c)).join(" ");
            return "Splitting a run and merging with " + cards + " from hand to form a new group.";
        }
        if (s2.type === "play" || s2.type === "place") {
            const cards = s2.handCards.map(c => cardHTML(c)).join(" ");
            return "Splitting a stack to make room, then playing " + cards + ".";
        }
    }
    return null;
}

function buildNarration(step, stepIdx) {
    const t = step.type;
    const p = '<span class="player-name">' + step.turnPlayer + '</span>';
    let text = "";
    let avatar = "cat_professor.webp";

    if (t === "setup") {
        const nStacks = step.board.length;
        const nCards = step.board.reduce((n, s) => n + s.board_cards.length, 0);
        text = "Starting position: " + nStacks + " stacks, " + nCards + " cards on the board.";
        avatar = "steve.png";
    } else if (t === "advance") {
        text = "Turn passes. It's now " + p + "'s turn. Let's see what they can do!";
    } else if (t === "complete") {
        const nStacks = step.board.length;
        const nCards = step.board.reduce((n, s) => n + s.board_cards.length, 0);
        text = p + " ends their turn. The board now has " + nStacks + " stacks with " + nCards + " cards.";
        avatar = "steve.png";
    } else if (t === "undo") {
        text = p + " takes back their last move. It happens to the best of us!";
        avatar = "oliver.png";
    } else if (t === "tidy") {
        text = p + " tidies up the board \u2014 nice and organized!";
    } else if (t === "move") {
        text = p + " repositions a stack.";
    } else if (t === "place") {
        const cards = step.handCards.map(c => cardHTML(c)).join(" ");
        text = p + " places " + cards + " from hand as a new stack.";
    } else if (t === "play") {
        const cards = step.handCards.map(c => cardHTML(c)).join(" ");
        text = p + " plays " + cards + " from hand, extending a stack.";
    } else if (t === "split") {
        const compound = detectCompound(stepIdx);
        if (compound) {
            text = p + ": " + compound;
        } else {
            text = p + " splits a stack into two pieces.";
        }
    } else if (t === "merge") {
        text = p + " merges two stacks together.";
    } else if (t === "rearrange") {
        text = p + " rearranges the board.";
    } else {
        text = "";
    }

    return '<img src="/static/' + avatar + '">' +
           '<div class="text">' + text + '</div>';
}

function buildSteps() {
    steps = [];
    if (EVENTS.length === 0) return;
    const first = EVENTS[0].payload;

    // Accept either a regular game_setup or a puzzle_setup.
    let initial_board;
    let initial_hands = [[], []];
    if (first.game_setup) {
        initial_board = first.game_setup.board.map(s => ({board_cards: s.board_cards, loc: s.loc}));
        initial_hands = [
            (first.game_setup.hands[0] || []).slice(),
            (first.game_setup.hands[1] || []).slice(),
        ];
    } else if (first.puzzle_setup) {
        initial_board = first.puzzle_setup.board_stacks.map(s => ({board_cards: s.board_cards, loc: s.loc}));
        initial_hands = [(first.puzzle_setup.player1_hand || []).slice(), []];
    } else {
        return;
    }

    let board = initial_board;
    let hands = [initial_hands[0].slice(), initial_hands[1].slice()];
    let turn = 1, turnPlayer = P1_NAME;

    steps.push({
        board: JSON.parse(JSON.stringify(board)),
        hands: [hands[0].slice(), hands[1].slice()],
        type: "setup", turn, turnPlayer, handCards: [],
    });

    for (let i = 1; i < EVENTS.length; i++) {
        const payload = EVENTS[i].payload;
        const info = classifyEvent(payload);
        board = applyMove(board, payload);

        let handCards = [];
        if (payload.json_game_event && payload.json_game_event.player_action) {
            handCards = (payload.json_game_event.player_action.hand_cards_to_release || []).map(h => h.card);
        }

        // Remove played cards from the active player's hand.
        const playerIdx = turnPlayer === P1_NAME ? 0 : 1;
        for (const c of handCards) {
            const h = hands[playerIdx];
            for (let k = 0; k < h.length; k++) {
                if (h[k].value === c.value && h[k].suit === c.suit && h[k].origin_deck === c.origin_deck) {
                    h.splice(k, 1);
                    break;
                }
            }
        }

        if (info.type === "advance") {
            turn++;
            turnPlayer = (turn %% 2 === 1) ? P1_NAME : P2_NAME;
        }

        steps.push({
            board: JSON.parse(JSON.stringify(board)),
            hands: [hands[0].slice(), hands[1].slice()],
            type: info.type, turn, turnPlayer, handCards,
        });
    }
}

// --- Canvas rendering ---
const canvas = document.getElementById("board");
const ctx = canvas.getContext("2d");

function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x+r,y); ctx.lineTo(x+w-r,y); ctx.arcTo(x+w,y,x+w,y+r,r);
    ctx.lineTo(x+w,y+h-r); ctx.arcTo(x+w,y+h,x+w-r,y+h,r);
    ctx.lineTo(x+r,y+h); ctx.arcTo(x,y+h,x,y+h-r,r);
    ctx.lineTo(x,y+r); ctx.arcTo(x,y,x+r,y,r);
    ctx.closePath();
}

function drawCard(x, y, card, highlighted) {
    const val = VN[card.value];
    const suit = SN[card.suit];
    const color = SC[card.suit];

    // Shadow.
    ctx.fillStyle = "rgba(0,0,0,0.08)";
    roundRect(x+1, y+1, CW, CH, 3);
    ctx.fill();

    // Body.
    ctx.fillStyle = highlighted ? "#fffacc" : "white";
    roundRect(x, y, CW, CH, 3);
    ctx.fill();

    // Border — blue like Angry Cat.
    ctx.strokeStyle = highlighted ? "#c8a000" : "#0000cc";
    ctx.lineWidth = 1;
    roundRect(x, y, CW, CH, 3);
    ctx.stroke();

    // Two-line layout: value on top, suit on bottom.
    ctx.fillStyle = color;

    // Value.
    ctx.font = "bold 16px sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(val, x + CW/2, y + CH * 0.33);

    // Suit.
    ctx.font = "16px sans-serif";
    ctx.fillText(suit, x + CW/2, y + CH * 0.7);
}

function drawBoard(step) {
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const hl = new Set();
    for (const c of step.handCards) hl.add(c.value+","+c.suit+","+c.origin_deck);

    for (const stack of step.board) {
        for (let i = 0; i < stack.board_cards.length; i++) {
            const bc = stack.board_cards[i];
            const x = stack.loc.left + i * PITCH;
            const y = stack.loc.top;
            const key = bc.card.value+","+bc.card.suit+","+bc.card.origin_deck;
            drawCard(x, y, bc.card, hl.has(key));
        }
    }
}

// --- Move list sidebar ---
const ICONS = {
    setup: "\u{1F3B4}", place: "\u2660", play: "\u2660",
    complete: "\u2714", advance: "\u27A1", tidy: "\u2728",
    split: "\u2702", merge: "\u{1F4A5}", undo: "\u21A9",
    move: "\u2194", rearrange: "\u{1F500}", unknown: "?",
};
const SHORT = {
    setup: "Deal", advance: "Next turn", complete: "End turn",
    undo: "Undo", tidy: "Tidy", move: "Move", split: "Split",
    merge: "Merge", rearrange: "Rearrange", unknown: "?",
};

function stepLabel(s) {
    if (s.type === "place" || s.type === "play") {
        return s.handCards.map(c => VN[c.value]+SL[c.suit]).join(" ");
    }
    return SHORT[s.type] || s.type;
}

function updateMoveList() {
    const el = document.getElementById("move-list-wrap");
    let html = "";
    let lastTurn = 0;
    for (let i = 0; i < steps.length; i++) {
        const s = steps[i];
        if (s.turn !== lastTurn) {
            html += '<div class="ml-turn">Turn ' + s.turn + ' \u2014 ' + s.turnPlayer + '</div>';
            lastTurn = s.turn;
        }
        const cls = i === currentStep ? "ml-item active" : "ml-item";
        const icon = ICONS[s.type] || "";
        html += '<div class="' + cls + '" onclick="goTo(' + i + ')"><span class="ml-type">' + icon + '</span> ' + stepLabel(s) + '</div>';
    }
    el.innerHTML = html;
    const active = el.querySelector(".active");
    if (active) active.scrollIntoView({ block: "nearest" });
}

// --- Controls ---
function renderHands(step) {
    const el = document.getElementById("hands");
    const suit_order = [3, 2, 1, 0];
    function hand_html(name, cards) {
        if (cards.length === 0) return "";
        let html = '<div><b>' + name + "</b> (" + cards.length + ")<br>";
        for (const suit of suit_order) {
            const suit_cards = cards.filter(c => c.suit === suit).sort((a, b) => a.value - b.value);
            if (suit_cards.length === 0) continue;
            html += suit_cards.map(c => cardHTML(c)).join(" ") + "<br>";
        }
        html += "</div>";
        return html;
    }
    const p1 = hand_html(P1_NAME, step.hands[0] || []);
    const p2 = hand_html(P2_NAME, step.hands[1] || []);
    el.innerHTML = p1 + p2;
}

function render() {
    const step = steps[currentStep];
    drawBoard(step);
    renderHands(step);
    updateMoveList();

    const narr = buildNarration(step, currentStep);
    document.getElementById("narration").innerHTML = narr;

    const scrubber = document.getElementById("scrubber");
    scrubber.max = steps.length - 1;
    scrubber.value = currentStep;

    document.getElementById("step-label").textContent =
        currentStep + " / " + (steps.length - 1);
    document.getElementById("btn-prev").disabled = currentStep === 0;
    document.getElementById("btn-next").disabled = currentStep === steps.length - 1;
}

document.getElementById("scrubber").addEventListener("input", (e) => {
    goTo(parseInt(e.target.value));
});

function next() { if (currentStep < steps.length-1) { currentStep++; render(); } else stopAutoplay(); }
function prev() { if (currentStep > 0) { currentStep--; render(); } }
function goTo(i) { currentStep = i; render(); stopAutoplay(); }

function toggleAutoplay() {
    if (autoplayTimer) { stopAutoplay(); return; }
    document.getElementById("btn-play").textContent = "\u23F8 Pause";
    (function tick() {
        if (currentStep < steps.length-1) {
            currentStep++; render();
            autoplayTimer = setTimeout(tick, 2000);
        } else stopAutoplay();
    })();
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
