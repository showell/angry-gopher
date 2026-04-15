// Admin authentication: post-user-rip stub. No real auth — admin
// pages trust the caller like every other page. Kept as a thin
// compatibility shim so existing admin handlers (admin_ops.go,
// admin.go, admin_tables.go) keep their familiar `authenticateAdmin`
// + `handleAdminLogin` wire-up.

package main

import (
	"net/http"

	"angry-gopher/auth"
)

// authenticateAdmin returns the caller's user id. Always succeeds
// (always > 0) under the trust-on-assertion auth model.
func authenticateAdmin(r *http.Request) int {
	return auth.Authenticate(r)
}

// handleAdminLogin used to render a login form; post-rip it redirects
// straight to /admin/. Kept on the mux so old bookmarks don't 404.
func handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/admin/", http.StatusSeeOther)
}
