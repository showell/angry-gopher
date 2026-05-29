// split_auth_data moves the account (name + password + api-key) and the id
// registry (next-id.txt) out of {data_dir}/users into the shared {auth_dir},
// and renames the gopher-private last-active -> last-seen in place. The
// account becomes the shared, backup-excluded store; admin / last-seen /
// upload-bytes stay under {data_dir}/users/<id>/.
//
// One-shot, idempotent: re-running finds nothing left to move (it never
// clobbers a file already at the destination). Run with the gopher server
// STOPPED — it moves the very files the running server reads.
//
//	go run ./tools/split_auth_data/ <data-dir> <auth-dir>
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: split_auth_data <data-dir> <auth-dir>")
		os.Exit(1)
	}
	dataDir, authDir := os.Args[1], os.Args[2]
	usersDir := filepath.Join(dataDir, "users")

	if err := os.MkdirAll(authDir, 0o755); err != nil {
		fail("mkdir auth dir %s: %v", authDir, err)
	}

	if moveFile(filepath.Join(usersDir, "next-id.txt"), filepath.Join(authDir, "next-id.txt")) {
		fmt.Println("moved next-id.txt -> auth")
	}

	entries, err := os.ReadDir(usersDir)
	if err != nil {
		fail("read %s: %v", usersDir, err)
	}
	nUsers := 0
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		id := e.Name()
		if _, err := strconv.Atoi(id); err != nil {
			continue // not a numeric user-id dir
		}
		nUsers++
		nAcct := 0
		for _, f := range []string{"name", "password", "api-key"} {
			if moveFile(filepath.Join(usersDir, id, f), filepath.Join(authDir, id, f)) {
				nAcct++
			}
		}
		msg := ""
		if moveFile(filepath.Join(usersDir, id, "last-active"), filepath.Join(usersDir, id, "last-seen")) {
			msg = ", last-active->last-seen"
		}
		fmt.Printf("  user %s: %d account file(s) -> auth%s\n", id, nAcct, msg)
	}
	fmt.Printf("done: %d user(s); account store now at %s\n", nUsers, authDir)
}

// moveFile renames src->dst when src exists and dst does not (so a re-run is a
// no-op and never clobbers). Creates dst's parent. Returns true if it moved.
func moveFile(src, dst string) bool {
	if _, err := os.Stat(src); err != nil {
		return false
	}
	if _, err := os.Stat(dst); err == nil {
		return false
	}
	_ = os.MkdirAll(filepath.Dir(dst), 0o755)
	if err := os.Rename(src, dst); err != nil {
		fail("move %s -> %s: %v", src, dst, err)
	}
	return true
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "split_auth_data: "+format+"\n", a...)
	os.Exit(1)
}
