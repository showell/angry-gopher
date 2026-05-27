// create_agent bootstraps an agent user (a bot principal: no password,
// only an API key) directly against an on-disk data dir. The companion
// to tools/create_user; agents are the password-free path for bots.
//
// Today there's exactly one agent slot — Claude, hardcoded as uid 3 in
// users.IsAgent — so this tool refuses to run unless the data dir's
// next-id is 3 (otherwise the allocated id wouldn't be the magic one).
// Generalize when a second agent appears.
//
// Usage:
//
//	./create_agent <data-root> <name>
//
// Prints two lines to stdout: the allocated uid, then the freshly-
// generated API key. Capture both:
//
//	out=$(./create_agent ~/AngryGopher/prod Claude)
//	uid=$(echo "$out" | sed -n 1p); key=$(echo "$out" | sed -n 2p)
//
// Save the key somewhere safe (it can be Show-API-Key'd later via
// /admin, but the easier path is to write it locally as the bot's
// credential file the same way the regular user's key lives at
// ~/.gopher_api_key).
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"angry-gopher/server/users"
)

// expectedAgentID matches the hardcoded uid in users.IsAgent. Update
// both when a second agent is added.
const expectedAgentID = "3"

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: create_agent <data-root> <name>")
		os.Exit(2)
	}
	dataRoot, name := os.Args[1], strings.TrimSpace(os.Args[2])
	if name == "" {
		fmt.Fprintln(os.Stderr, "create_agent: empty name")
		os.Exit(2)
	}

	users.SetUsersRoot(filepath.Join(dataRoot, "users"))

	// Cross-check that the next allocation will land on the agent slot.
	nextIDFile := filepath.Join(dataRoot, "users", "next-id.txt")
	if b, err := os.ReadFile(nextIDFile); err == nil {
		if next := strings.TrimSpace(string(b)); next != expectedAgentID {
			fmt.Fprintf(os.Stderr,
				"create_agent: next-id is %q, but the agent slot is uid %q; "+
					"refusing so we don't allocate an agent at the wrong id\n",
				next, expectedAgentID)
			os.Exit(1)
		}
	} else {
		fmt.Fprintf(os.Stderr, "create_agent: read %s: %v\n", nextIDFile, err)
		os.Exit(1)
	}

	if id, ok := users.FindMemberByName(name); ok {
		fmt.Fprintf(os.Stderr, "create_agent: a member named %q already exists (id %s); refusing\n", name, id)
		os.Exit(1)
	}
	if users.UserExists(expectedAgentID) {
		fmt.Fprintf(os.Stderr, "create_agent: uid %s already exists; refusing\n", expectedAgentID)
		os.Exit(1)
	}

	id, err := users.AllocateUser(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "create_agent: allocate:", err)
		os.Exit(1)
	}
	if got, want := id, expectedAgentID; got != want {
		fmt.Fprintf(os.Stderr,
			"create_agent: allocated id %s but expected %s — refusing to continue; "+
				"check next-id.txt and the user registry\n", got, want)
		os.Exit(1)
	}
	// Sanity: the just-allocated user must classify as an agent per
	// users.IsAgent (else our auth gates won't let them act).
	if !users.IsAgent(id) {
		fmt.Fprintf(os.Stderr, "create_agent: uid %s does not satisfy users.IsAgent; refusing\n", id)
		os.Exit(1)
	}
	key, err := users.SetUserAPIKey(id)
	if err != nil {
		fmt.Fprintln(os.Stderr, "create_agent: set api key:", err)
		os.Exit(1)
	}
	if _, err := strconv.Atoi(id); err != nil {
		// AllocateUser returns a decimal string, but be loud if that
		// ever changes — downstream callers parse the output.
		fmt.Fprintf(os.Stderr, "create_agent: allocated id %q is not numeric\n", id)
	}
	fmt.Println(id)
	fmt.Println(key)
}
