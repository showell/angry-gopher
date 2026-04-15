// Route dispatch functions — extracted from buildMux to keep
// the routing table clean.

package main

import (
	"net/http"
	"strings"

	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/presence"
	"angry-gopher/messages"
	"angry-gopher/reactions"
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
	if strings.Contains(r.URL.Path, "/subscriptions/") {
		channels.HandleGetSubscriptionStatus(w, r)
	} else if r.Method == "PATCH" {
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

func routeSubscriptions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		channels.HandleSubscriptions(w, r)
	case "POST":
		channels.HandleCreateChannel(w, r)
	case "DELETE":
		channels.HandleUnsubscribe(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func routeMessages(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		messages.HandleGetMessages(w, r)
	case "POST":
		messages.HandleSendMessage(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func routeMessageByID(w http.ResponseWriter, r *http.Request) {
	if strings.HasSuffix(r.URL.Path, "/reactions") {
		reactions.HandleReaction(w, r)
	} else if r.Method == "PATCH" {
		messages.HandleEditMessage(w, r)
	} else if r.Method == "GET" {
		messages.HandleGetSingleMessage(w, r)
	} else if r.Method == "DELETE" {
		messages.HandleDeleteMessage(w, r)
	} else {
		respond.Error(w, "Unknown messages sub-endpoint")
	}
}

func routeStreamByID(w http.ResponseWriter, r *http.Request) {
	if strings.HasSuffix(r.URL.Path, "/topics") {
		channels.HandleGetTopics(w, r)
	} else if strings.HasSuffix(r.URL.Path, "/subscribers") {
		channels.HandleGetSubscribers(w, r)
	} else if r.Method == "PATCH" {
		channels.HandleUpdateChannel(w, r)
	} else if r.Method == "GET" {
		channels.HandleGetChannel(w, r)
	} else {
		respond.Error(w, "Unknown streams sub-endpoint")
	}
}

func routePresence(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "POST":
		presence.HandleUpdatePresence(w, r)
	case "GET":
		presence.HandleGetPresence(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}
