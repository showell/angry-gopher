// session_check is the Go half of direction 2: it reads session_zig.jsonl
// (cookies the zig server would issue, signed by users.signSession) and asserts
// Go's REAL verifier (users.VerifySessionWith) — the same code that guards every
// live request — reproduces the recorded verdict for each. This is the
// reversibility guard: a session minted by a zig binary stays valid after a
// rollback to the Go binary.
//
// Exits non-zero on any mismatch. Reads zig-server/session_zig.jsonl (or the
// path given as the first argument).
package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"angry-gopher/server/users"
)

type row struct {
	ID     string `json:"id"`
	Secret string `json:"secret"`
	Cookie string `json:"cookie"`
	Now    int64  `json:"now"`
	Expect string `json:"expect"`
}

func main() {
	path := "zig-server/session_zig.jsonl"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()

	pass, fail := 0, 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r row
		if err := json.Unmarshal(line, &r); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		secret, err := hex.DecodeString(r.Secret)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		got, ok := users.VerifySessionWith(secret, r.Cookie, r.Now)
		if !ok {
			got = ""
		}
		if got == r.Expect {
			pass++
		} else {
			fail++
			fmt.Printf("FAILID\t%s\n  expect id=%q got id=%q\n  cookie: %s\n", r.ID, r.Expect, got, r.Cookie)
		}
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("== zig->Go session verify (direction 2): %d/%d passing  (%d failing)\n", pass, pass+fail, fail)
	if fail != 0 {
		os.Exit(1)
	}
}
