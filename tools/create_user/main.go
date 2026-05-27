// create_user allocates a new member (a user with a password) directly
// against an on-disk data dir, without going through the running server.
// Useful for bootstrapping bot identities (where we want a stable uid +
// API key but no interactive registration flow), and for adding members
// while the prod binary is up and we don't want to disturb its session
// cookies.
//
// Reads the password from stdin so it doesn't land in shell history /
// `ps`. Refuses if a member with the requested name already exists, so
// re-runs don't silently re-allocate.
//
// Usage:
//
//	./create_user <data-root> <name>
//	# password on stdin (single line)
//
// Example (prod):
//
//	read -s pw && echo "$pw" | ./create_user ~/AngryGopher/prod Claude
//
// Prints the allocated user id to stdout. Generate the API key
// separately via /admin once the user exists (Claude → Generate).
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"angry-gopher/server/users"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: create_user <data-root> <name>")
		fmt.Fprintln(os.Stderr, "  password on stdin (single line)")
		os.Exit(2)
	}
	dataRoot, name := os.Args[1], strings.TrimSpace(os.Args[2])
	if name == "" {
		fmt.Fprintln(os.Stderr, "create_user: empty name")
		os.Exit(2)
	}

	users.SetUsersRoot(dataRoot + "/users")

	if id, ok := users.FindMemberByName(name); ok {
		fmt.Fprintf(os.Stderr, "create_user: a member named %q already exists (id %s); refusing\n", name, id)
		os.Exit(1)
	}

	// Single line of stdin = the password.
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 4096), 4096)
	if !sc.Scan() {
		fmt.Fprintln(os.Stderr, "create_user: no password on stdin")
		os.Exit(2)
	}
	password := sc.Text()
	if password == "" {
		fmt.Fprintln(os.Stderr, "create_user: empty password")
		os.Exit(2)
	}

	id, err := users.AllocateUser(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "create_user: allocate:", err)
		os.Exit(1)
	}
	if err := users.SetUserPassword(id, password); err != nil {
		fmt.Fprintln(os.Stderr, "create_user: set password:", err)
		os.Exit(1)
	}
	fmt.Println(id)
}
