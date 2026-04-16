// Admin UI router. Dispatches to:
//   admin_auth.go   — login, session cookies
//   admin_ops.go    — ops dashboard, health check, reset
//   admin_tables.go — table viewer, presence, DB helpers

package main

import (
	"net/http"
	"strings"
)

func adminHandler(w http.ResponseWriter, r *http.Request) {
	if authenticateAdmin(r) == 0 {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return
	}

	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	tableName := ""
	if len(parts) > 1 {
		tableName = parts[1]
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if tableName == "" {
		renderAdminIndex(w)
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
