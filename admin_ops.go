// Ops dashboard, health check, and reset handler.

package main

import (
	"encoding/json"
	"fmt"
	"html"
	"log"
	"net/http"
	"sort"
	"time"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/presence"
	"angry-gopher/ratelimit"
)

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

	var inviteCount int
	DB.QueryRow(`SELECT COUNT(*) FROM invites WHERE expires_at > ?`, time.Now().Unix()).Scan(&inviteCount)
	fmt.Fprintf(w, `<div class="stat-box"><div class="stat">%d</div><div class="stat-label">Active Invites</div></div>`, inviteCount)
	fmt.Fprint(w, `</div>`)

	// --- Event Queues ---
	fmt.Fprint(w, `<h2>Event Queues</h2>`)
	if len(queueStats) == 0 {
		fmt.Fprint(w, `<p>No registered queues.</p>`)
	} else {
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
<tr><td><b>Started</b></td><td>%s (%s ago)</td></tr>
<tr><td><b>Git Commit</b></td><td><code>%s</code></td></tr>`,
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

	fmt.Fprint(w, `</body></html>`)
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
		LastPollSecs int    `json:"last_poll_secs"`
	}
	type rlUserInfo struct {
		UserID   int `json:"user_id"`
		Requests int `json:"requests"`
		Headroom int `json:"headroom"`
	}
	type healthData struct {
		UptimeSecs   int          `json:"uptime_secs"`
		GitCommit    string       `json:"git_commit"`
		Queues       []queueInfo  `json:"queues"`
		OnlineUsers  int          `json:"online_users"`
		Rejected429s int          `json:"rejected_429s"`
		RLUsers      []rlUserInfo `json:"rate_limit_users"`
		RLMax        int          `json:"rate_limit_max"`
	}

	data := healthData{
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
