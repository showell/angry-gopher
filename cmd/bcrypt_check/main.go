// bcrypt_check is the Go half of direction 2: it reads bcrypt_zig.jsonl (hashes
// the zig server would produce, `$2b$`) and asserts Go's
// golang.org/x/crypto/bcrypt — the live site's library — accepts each for its
// correct password and rejects a tampered one. This is the reversibility guard:
// proof that rolling back from a zig binary to the Go binary keeps every login
// working.
//
// Exits non-zero on any mismatch. Reads zig-server/bcrypt_zig.jsonl (or the path
// given as the first argument).
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"golang.org/x/crypto/bcrypt"
)

type row struct {
	ID       string `json:"id"`
	Password string `json:"password"`
	Hash     string `json:"hash"`
}

func main() {
	path := "zig-server/bcrypt_zig.jsonl"
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
		// correct password must verify; tampered password must not
		if err := bcrypt.CompareHashAndPassword([]byte(r.Hash), []byte(r.Password)); err != nil {
			fail++
			fmt.Printf("FAILID\t%s\n  Go rejected zig hash for correct password: %v\n", r.ID, err)
			continue
		}
		if bcrypt.CompareHashAndPassword([]byte(r.Hash), []byte(r.Password+"X")) == nil {
			fail++
			fmt.Printf("FAILID\t%s\n  Go accepted a tampered password\n", r.ID)
			continue
		}
		pass++
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("== zig->Go verify (direction 2): %d/%d passing  (%d failing)\n", pass, pass+fail, fail)
	if fail != 0 {
		os.Exit(1)
	}
}
