// Ops dashboard and health check. With the messaging stack ripped
// 2026-04-21 these are minimal — just server uptime and build info.

package main

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"time"

	"angry-gopher/auth"
)

func renderOpsDashboard(w http.ResponseWriter) {
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Ops Dashboard — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
h2 { color: #000080; margin-top: 28px; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 8px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
</style>
</head><body>
<a href="/admin/">← Back</a>
<h1>🔧 Ops Dashboard</h1>
<h2>Server Session</h2>`)

	now := time.Now()
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
	fmt.Fprint(w, `</table></body></html>`)
}

func handleHealthCheck(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 || !auth.IsAdmin(userID) {
		http.Error(w, "Admin access required", http.StatusForbidden)
		return
	}

	data := map[string]interface{}{
		"uptime_secs": int(time.Since(serverStartTime).Seconds()),
		"git_commit":  gitCommit,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}
