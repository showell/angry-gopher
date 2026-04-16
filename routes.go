// Route dispatch functions — extracted from buildMux to keep
// the routing table clean.

package main

import (
	"net/http"

	"angry-gopher/events"
	"angry-gopher/respond"
	"angry-gopher/users"
)

func routeEvents(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		events.HandleEvents(w, r)
	case "DELETE":
		events.HandleDeleteQueue(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func routeOwnUser(w http.ResponseWriter, r *http.Request) {
	users.HandleGetOwnUser(w, r)
}

func routeUserByID(w http.ResponseWriter, r *http.Request) {
	if r.Method == "PATCH" {
		users.HandleUpdateUser(w, r)
	} else {
		users.HandleGetUser(w, r)
	}
}

func routeUsers(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		users.HandleCreateUser(w, r)
	} else {
		users.HandleUsers(w, r)
	}
}
