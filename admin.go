// Admin UI for inspecting the Angry Gopher database.
// Serves a simple HTML page at /admin/ that shows all tables and
// their contents, similar to Django's admin interface.

package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/presence"
	"angry-gopher/ratelimit"
)

// Session cookie signing key — regenerated on each server start,
// so sessions don't survive restarts. That's fine for admin use.
var sessionKey []byte

func init() {
	sessionKey = make([]byte, 32)
	rand.Read(sessionKey)
}

func signSession(userID int) string {
	payload := strconv.Itoa(userID)
	mac := hmac.New(sha256.New, sessionKey)
	mac.Write([]byte(payload))
	sig := hex.EncodeToString(mac.Sum(nil))
	return payload + "." + sig
}

func verifySession(cookie string) int {
	parts := strings.SplitN(cookie, ".", 2)
	if len(parts) != 2 {
		return 0
	}
	userID, err := strconv.Atoi(parts[0])
	if err != nil || userID == 0 {
		return 0
	}
	mac := hmac.New(sha256.New, sessionKey)
	mac.Write([]byte(parts[0]))
	expected := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(parts[1]), []byte(expected)) {
		return 0
	}
	return userID
}

// authenticateAdmin checks for a valid admin session cookie first,
// then falls back to Basic auth (used by CLI tools like health_check).
func authenticateAdmin(r *http.Request) int {
	if c, err := r.Cookie("gopher_admin"); err == nil {
		if userID := verifySession(c.Value); userID != 0 && auth.IsAdmin(userID) {
			return userID
		}
	}
	userID := auth.Authenticate(r)
	if userID != 0 && auth.IsAdmin(userID) {
		return userID
	}
	return 0
}

func adminHandler(w http.ResponseWriter, r *http.Request) {
	if authenticateAdmin(r) == 0 {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return
	}

	// Parse which table to show (default: overview of all tables).
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	tableName := ""
	if len(parts) > 1 {
		tableName = parts[1]
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if tableName == "" {
		renderAdminIndex(w)
	} else if tableName == "presence" {
		renderAdminPresence(w)
	} else if tableName == "ops" {
		if r.Method == "POST" {
			handleOpsReset(w, r)
			return
		}
		renderOpsDashboard(w)
	} else {
		renderAdminTable(w, tableName)
	}
}

func renderAdminIndex(w http.ResponseWriter) {
	tables := getTableNames()

	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Angry Gopher Admin</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
a { color: #000080; font-weight: bold; font-size: 18px; }
.table-list { display: flex; flex-direction: column; gap: 8px; }
.count { color: #888; margin-left: 8px; }
</style>
</head><body>
<h1>🐹 Angry Gopher Admin</h1>
<div class="table-list">`)

	for _, name := range tables {
		count := getRowCount(name)
		fmt.Fprintf(w, `<div><a href="/admin/%s">%s</a><span class="count">(%d rows)</span></div>`,
			html.EscapeString(name), html.EscapeString(name), count)
	}

	fmt.Fprint(w, `</div>`)

	// In-memory data sections.
	fmt.Fprint(w, `<h2 style="color:#000080;margin-top:30px">In-Memory State</h2>`)
	fmt.Fprint(w, `<div class="table-list">`)
	fmt.Fprint(w, `<div><a href="/admin/presence">presence</a><span class="count">(live)</span></div>`)
	fmt.Fprint(w, `<div><a href="/admin/ops">ops dashboard</a><span class="count">(live)</span></div>`)
	fmt.Fprint(w, `</div>`)

	fmt.Fprint(w, `</body></html>`)
}

func renderAdminTable(w http.ResponseWriter, tableName string) {
	// Validate table name to prevent SQL injection.
	if !isValidTable(tableName) {
		http.Error(w, "Unknown table", http.StatusNotFound)
		return
	}

	columns, rows := getTableData(tableName)

	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher Admin</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 12px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; max-width: 400px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
tr:hover td { background: #f0f0ff; }
</style>
</head><body>
<a href="/admin/">← Back to tables</a>
<h1>%s</h1>`, html.EscapeString(tableName), html.EscapeString(tableName))

	if len(rows) == 0 {
		fmt.Fprint(w, `<p>No rows.</p>`)
	} else {
		fmt.Fprint(w, `<table><thead><tr>`)
		for _, col := range columns {
			fmt.Fprintf(w, `<th>%s</th>`, html.EscapeString(col))
		}
		fmt.Fprint(w, `</tr></thead><tbody>`)

		for _, row := range rows {
			fmt.Fprint(w, `<tr>`)
			for _, cell := range row {
				fmt.Fprintf(w, `<td>%s</td>`, html.EscapeString(cell))
			}
			fmt.Fprint(w, `</tr>`)
		}

		fmt.Fprint(w, `</tbody></table>`)
	}

	fmt.Fprintf(w, `<p style="color:#888">%d rows</p>`, len(rows))
	fmt.Fprint(w, `</body></html>`)
}

func renderAdminPresence(w http.ResponseWriter) {
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Presence — Angry Gopher Admin</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 12px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
.active { color: green; font-weight: bold; }
.idle { color: orange; font-weight: bold; }
.offline { color: #999; }
</style>
</head><body>
<a href="/admin/">← Back to tables</a>
<h1>User Presence</h1>`)

	entries := presence.GetAll()
	now := time.Now()

	if len(entries) == 0 {
		fmt.Fprint(w, `<p>No presence data yet.</p>`)
	} else {
		fmt.Fprint(w, `<table><thead><tr><th>User ID</th><th>Name</th><th>Status</th><th>Last Seen</th></tr></thead><tbody>`)

		for userID, ts := range entries {
			var fullName string
			DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&fullName)

			ago := now.Sub(ts).Truncate(time.Second)

			cssClass := "active"
			status := "online"
			if ago >= presence.OfflineThreshold {
				cssClass = "offline"
				status = "offline"
			}

			fmt.Fprintf(w, `<tr><td>%d</td><td>%s</td><td class="%s">%s</td><td>%s ago</td></tr>`,
				userID,
				html.EscapeString(fullName),
				cssClass,
				status,
				ago,
			)
		}

		fmt.Fprint(w, `</tbody></table>`)
	}

	fmt.Fprintf(w, `<p style="color:#888">%d entries</p>`, len(entries))
	fmt.Fprint(w, `</body></html>`)
}

func renderOpsDashboard(w http.ResponseWriter) {
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Ops Dashboard — Angry Gopher</title>
<meta http-equiv="refresh" content="10">
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
h2 { color: #000080; margin-top: 28px; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 8px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
.ok { color: green; font-weight: bold; }
.warn { color: orange; font-weight: bold; }
.stat { font-size: 28px; font-weight: bold; color: #000080; }
.stat-label { font-size: 14px; color: #666; }
.stats-row { display: flex; gap: 40px; margin: 12px 0; }
.stat-box { text-align: center; }
</style>
</head><body>
<a href="/admin/">← Back</a>
<h1>🔧 Ops Dashboard</h1>
<p style="color:#888;font-size:13px">Auto-refreshes every 10 seconds</p>
<form method="POST" style="margin:12px 0" onsubmit="return confirm('Reset all ops counters and queues?')">
<button type="submit" style="background:#cc0000;color:white;border:none;padding:8px 20px;font-size:14px;font-weight:bold;cursor:pointer;border-radius:4px">Reset All</button>
</form>`)

	// --- Summary stats ---
	now := time.Now()
	queueStats := events.Stats()
	onlineIDs := presence.OnlineUserIDs()
	rejected429s, userRLStats := ratelimit.Stats()

	fmt.Fprint(w, `<div class="stats-row">`)
	fmt.Fprintf(w, `<div class="stat-box"><div class="stat">%d</div><div class="stat-label">Event Queues</div></div>`, len(queueStats))
	fmt.Fprintf(w, `<div class="stat-box"><div class="stat">%d</div><div class="stat-label">Users Online</div></div>`, len(onlineIDs))
	fmt.Fprintf(w, `<div class="stat-box"><div class="stat">%d</div><div class="stat-label">429s Sent</div></div>`, rejected429s)

	// Count unexpired invites.
	var inviteCount int
	DB.QueryRow(`SELECT COUNT(*) FROM invites WHERE expires_at > ?`, time.Now().Unix()).Scan(&inviteCount)
	fmt.Fprintf(w, `<div class="stat-box"><div class="stat">%d</div><div class="stat-label">Active Invites</div></div>`, inviteCount)
	fmt.Fprint(w, `</div>`)

	// --- Event Queues ---
	fmt.Fprint(w, `<h2>Event Queues</h2>`)
	if len(queueStats) == 0 {
		fmt.Fprint(w, `<p>No registered queues.</p>`)
	} else {
		// Look up user names.
		fmt.Fprint(w, `<table><thead><tr><th>Queue ID</th><th>User</th><th>Pending Events</th><th>Last Event ID</th><th>Last Poll</th></tr></thead><tbody>`)
		sort.Slice(queueStats, func(i, j int) bool {
			return queueStats[i].ID < queueStats[j].ID
		})
		for _, q := range queueStats {
			var fullName string
			DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, q.UserID).Scan(&fullName)
			if fullName == "" {
				fullName = fmt.Sprintf("user %d", q.UserID)
			}
			lastPoll := "never"
			pollClass := "warn"
			if !q.LastPollTime.IsZero() {
				ago := now.Sub(q.LastPollTime).Truncate(time.Second)
				lastPoll = fmt.Sprintf("%s ago", ago)
				if ago < 2*time.Minute {
					pollClass = "ok"
				}
			}
			fmt.Fprintf(w, `<tr><td>%s</td><td>%s (id %d)</td><td>%d</td><td>%d</td><td class="%s">%s</td></tr>`,
				html.EscapeString(q.ID),
				html.EscapeString(fullName),
				q.UserID,
				q.EventCount,
				q.LastID,
				pollClass,
				lastPoll,
			)
		}
		fmt.Fprint(w, `</tbody></table>`)
	}

	// --- Presence ---
	fmt.Fprint(w, `<h2>Presence</h2>`)
	allPresence := presence.GetAll()
	if len(allPresence) == 0 {
		fmt.Fprint(w, `<p>No presence data.</p>`)
	} else {
		now := time.Now()
		fmt.Fprint(w, `<table><thead><tr><th>User</th><th>Status</th><th>Last Seen</th></tr></thead><tbody>`)
		for userID, ts := range allPresence {
			var fullName string
			DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&fullName)
			if fullName == "" {
				fullName = fmt.Sprintf("user %d", userID)
			}
			ago := now.Sub(ts).Truncate(time.Second)
			cssClass := "ok"
			status := "online"
			if ago >= presence.OfflineThreshold {
				cssClass = "warn"
				status = "offline"
			}
			fmt.Fprintf(w, `<tr><td>%s (id %d)</td><td class="%s">%s</td><td>%s ago</td></tr>`,
				html.EscapeString(fullName), userID, cssClass, status, ago)
		}
		fmt.Fprint(w, `</tbody></table>`)
	}

	// --- Rate Limiting ---
	fmt.Fprint(w, `<h2>Rate Limiting</h2>`)
	fmt.Fprintf(w, `<p>Window: %d requests / %s — Total 429s served: <b>%d</b></p>`,
		ratelimit.MaxRequests, ratelimit.Window, rejected429s)
	if len(userRLStats) == 0 {
		fmt.Fprint(w, `<p>No active users in current window.</p>`)
	} else {
		sort.Slice(userRLStats, func(i, j int) bool {
			return userRLStats[i].RequestsInWindow > userRLStats[j].RequestsInWindow
		})
		fmt.Fprint(w, `<table><thead><tr><th>User</th><th>Requests in Window</th><th>Headroom</th></tr></thead><tbody>`)
		for _, u := range userRLStats {
			var fullName string
			DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, u.UserID).Scan(&fullName)
			if fullName == "" {
				fullName = fmt.Sprintf("user %d", u.UserID)
			}
			headroom := ratelimit.MaxRequests - u.RequestsInWindow
			cssClass := "ok"
			if headroom < 20 {
				cssClass = "warn"
			}
			fmt.Fprintf(w, `<tr><td>%s (id %d)</td><td>%d</td><td class="%s">%d</td></tr>`,
				html.EscapeString(fullName), u.UserID, u.RequestsInWindow, cssClass, headroom)
		}
		fmt.Fprint(w, `</tbody></table>`)
	}

	// --- Server Session ---
	fmt.Fprint(w, `<h2>Server Session</h2>`)
	uptime := now.Sub(serverStartTime).Truncate(time.Second)
	fmt.Fprintf(w, `<table>
<tr><td><b>Generation</b></td><td>%d</td></tr>
<tr><td><b>Started</b></td><td>%s (%s ago)</td></tr>
<tr><td><b>Git Commit</b></td><td><code>%s</code></td></tr>`,
		currentGeneration,
		serverStartTime.Format("2006-01-02 15:04:05"),
		uptime,
		html.EscapeString(gitCommit),
	)
	if serverConfig != nil {
		fmt.Fprintf(w, `
<tr><td><b>Mode</b></td><td>%s</td></tr>
<tr><td><b>Database</b></td><td><code>%s</code></td></tr>
<tr><td><b>Listening</b></td><td>%s</td></tr>`,
			html.EscapeString(serverConfig.Mode),
			html.EscapeString(serverConfig.DBPath()),
			html.EscapeString(serverConfig.ListenAddr()),
		)
	}
	fmt.Fprint(w, `</table>`)

	// --- User Sessions ---
	fmt.Fprint(w, `<h2>User Sessions</h2>`)
	usRows, err := DB.Query(`
		SELECT us.user_id, u.full_name, us.generation, us.logged_in_at
		FROM user_sessions us
		JOIN users u ON us.user_id = u.id
		ORDER BY us.id DESC
		LIMIT 20`)
	if err == nil {
		defer usRows.Close()
		fmt.Fprint(w, `<table><thead><tr><th>User</th><th>Generation</th><th>Logged In</th></tr></thead><tbody>`)
		rowCount := 0
		for usRows.Next() {
			var userID, gen int
			var fullName, loggedIn string
			usRows.Scan(&userID, &fullName, &gen, &loggedIn)
			genClass := "ok"
			if gen != currentGeneration {
				genClass = "warn"
			}
			fmt.Fprintf(w, `<tr><td>%s (id %d)</td><td class="%s">%d</td><td>%s</td></tr>`,
				html.EscapeString(fullName), userID, genClass, gen, html.EscapeString(loggedIn))
			rowCount++
		}
		fmt.Fprint(w, `</tbody></table>`)
		if rowCount == 0 {
			fmt.Fprint(w, `<p>No user sessions recorded yet.</p>`)
		}
	}

	fmt.Fprint(w, `</body></html>`)
}

func handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		r.ParseForm()
		email := r.FormValue("email")
		apiKey := r.FormValue("api_key")

		var userID int
		err := DB.QueryRow(`SELECT id FROM users WHERE email = ? AND api_key = ? AND is_admin = 1`,
			email, apiKey).Scan(&userID)
		if err != nil || userID == 0 {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, adminLoginPage("Invalid credentials or not an admin."))
			return
		}

		http.SetCookie(w, &http.Cookie{
			Name:     "gopher_admin",
			Value:    signSession(userID),
			Path:     "/admin/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
		http.Redirect(w, r, "/admin/", http.StatusSeeOther)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, adminLoginPage(""))
}

func adminLoginPage(errMsg string) string {
	errorHTML := ""
	if errMsg != "" {
		errorHTML = fmt.Sprintf(`<p style="color:red;font-weight:bold">%s</p>`, html.EscapeString(errMsg))
	}
	return fmt.Sprintf(`<!DOCTYPE html>
<html><head><title>Admin Login — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 400px; }
h1 { color: #000080; }
label { display: block; margin-top: 12px; font-weight: bold; }
input { width: 100%%; padding: 6px; margin-top: 4px; font-size: 14px; box-sizing: border-box; }
button { margin-top: 16px; padding: 8px 20px; font-size: 14px; background: #000080; color: white; border: none; cursor: pointer; border-radius: 4px; }
</style>
</head><body>
<h1>Admin Login</h1>
%s
<form method="POST">
<label>Email<input type="email" name="email" required autofocus></label>
<label>API Key<input type="password" name="api_key" required></label>
<button type="submit">Log in</button>
</form>
</body></html>`, errorHTML)
}

func handleHealthCheck(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 || !auth.IsAdmin(userID) {
		http.Error(w, "Admin access required", http.StatusForbidden)
		return
	}

	queueStats := events.Stats()
	onlineIDs := presence.OnlineUserIDs()
	rejected429s, userRLStats := ratelimit.Stats()

	type queueInfo struct {
		ID           string `json:"id"`
		UserID       int    `json:"user_id"`
		Pending      int    `json:"pending"`
		LastID       int    `json:"last_id"`
		LastPollSecs int    `json:"last_poll_secs"` // seconds since last poll, -1 if never
	}
	type rlUserInfo struct {
		UserID   int `json:"user_id"`
		Requests int `json:"requests"`
		Headroom int `json:"headroom"`
	}
	type healthData struct {
		Generation   int          `json:"generation"`
		UptimeSecs   int          `json:"uptime_secs"`
		GitCommit    string       `json:"git_commit"`
		Queues       []queueInfo  `json:"queues"`
		OnlineUsers  int          `json:"online_users"`
		Rejected429s int          `json:"rejected_429s"`
		RLUsers      []rlUserInfo `json:"rate_limit_users"`
		RLMax        int          `json:"rate_limit_max"`
	}

	data := healthData{
		Generation:   currentGeneration,
		UptimeSecs:   int(time.Since(serverStartTime).Seconds()),
		GitCommit:    gitCommit,
		OnlineUsers:  len(onlineIDs),
		Rejected429s: rejected429s,
		RLMax:        ratelimit.MaxRequests,
	}
	now := time.Now()
	for _, q := range queueStats {
		pollSecs := -1
		if !q.LastPollTime.IsZero() {
			pollSecs = int(now.Sub(q.LastPollTime).Seconds())
		}
		data.Queues = append(data.Queues, queueInfo{
			ID:           q.ID,
			UserID:       q.UserID,
			Pending:      q.EventCount,
			LastID:        q.LastID,
			LastPollSecs: pollSecs,
		})
	}
	for _, u := range userRLStats {
		data.RLUsers = append(data.RLUsers, rlUserInfo{
			UserID:   u.UserID,
			Requests: u.RequestsInWindow,
			Headroom: ratelimit.MaxRequests - u.RequestsInWindow,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func handleOpsReset(w http.ResponseWriter, r *http.Request) {
	events.Reset()
	presence.Reset()
	ratelimit.Reset()
	log.Println("[admin] Ops reset: cleared all queues, presence, and rate limit counters")
	http.Redirect(w, r, "/admin/ops", http.StatusSeeOther)
}

// --- Database helpers for admin ---

func getTableNames() []string {
	rows, err := DB.Query(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var tables []string
	for rows.Next() {
		var name string
		rows.Scan(&name)
		tables = append(tables, name)
	}
	return tables
}

func isValidTable(name string) bool {
	for _, t := range getTableNames() {
		if t == name {
			return true
		}
	}
	return false
}

func getRowCount(tableName string) int {
	var count int
	// tableName is validated by isValidTable before use.
	DB.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", tableName)).Scan(&count)
	return count
}

func getTableData(tableName string) ([]string, [][]string) {
	// tableName is validated by isValidTable before use.
	rows, err := DB.Query(fmt.Sprintf("SELECT * FROM %s LIMIT 200", tableName))
	if err != nil {
		return nil, nil
	}
	defer rows.Close()

	columns, _ := rows.Columns()

	var result [][]string
	for rows.Next() {
		values := make([]interface{}, len(columns))
		ptrs := make([]interface{}, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		rows.Scan(ptrs...)

		row := make([]string, len(columns))
		for i, v := range values {
			row[i] = fmt.Sprintf("%v", v)
		}
		result = append(result, row)
	}

	return columns, result
}
