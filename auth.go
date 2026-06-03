package main

import (
	"net/http"
	"net/url"

	"angry-gopher/server/users"
)

// AuthStrategy names who may reach a route. Every route declares one at
// registration; Gated wraps the handler with the strategy's check before
// invocation, so handlers themselves stop checking auth. The strategy IS
// the route's authorization contract — single declared point, no
// scattered defensive re-checks.
type AuthStrategy int

const (
	// TOTALLY_PUBLIC: anyone, including visitors with no cookie. Home,
	// Learn, login/logout, /version.
	TOTALLY_PUBLIC AuthStrategy = iota

	// JUST_NEEDS_NAME: any identified principal (guest cookie, member
	// session, or agent key). Lyn Rummy's game and puzzles surfaces.
	// No identity → redirect to /login.
	JUST_NEEDS_NAME

	// NEED_PASSWORD: an authorized principal (member session OR agent
	// API key). Chat + docs + their assets. Not authorized → redirect
	// to /login/full?next=<path>.
	NEED_PASSWORD

	// ADMIN_ONLY: member session with the Admin flag. /admin. Not admin
	// → 404 (don't reveal the surface).
	ADMIN_ONLY
)

// Gated wraps h with the access check for s.
func Gated(s AuthStrategy, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch s {
		case TOTALLY_PUBLIC:
		case JUST_NEEDS_NAME:
			if users.CurrentUser(r).ID == "" {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
				return
			}
		case NEED_PASSWORD:
			if !users.IsAuthorized(r) {
				http.Redirect(w, r, "/login/full?next="+url.QueryEscape(r.URL.Path), http.StatusSeeOther)
				return
			}
		case ADMIN_ONLY:
			if !users.CurrentUser(r).Admin {
				http.NotFound(w, r)
				return
			}
		}
		h(w, r)
	}
}

// Route registers one routed page or asset with its authorization
// strategy. Reads "<pattern>, <strategy>, <handler>" left-to-right — the
// strategy sits between path and code so it's hard to skim past.
func Route(mux *http.ServeMux, pattern string, s AuthStrategy, h http.HandlerFunc) {
	mux.HandleFunc(pattern, Gated(s, h))
}
