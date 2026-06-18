// bcrypt_gold generates the cross-validation fixture the zig port must satisfy:
// synthetic (password, hash) pairs where the hash is produced by Go's
// golang.org/x/crypto/bcrypt — the SAME library that hashed every real stored
// password on the live site. The zig harness (check_bcrypt.zig) reads this and
// must agree on every verify verdict.
//
// Why this fixture exists at all: bcrypt is salted, so its output is
// non-deterministic — you cannot freeze a byte-snapshot the way the markdown
// gold does. The oracle here is a VERIFICATION TABLE, not a recording: each row
// asserts "verify(password, hash) == expect". And there is no eyeball backstop
// — a correct hash and a wrong one are both 60 chars of base64 noise — so this
// table is the only instrument that can tell a working bcrypt from a broken one.
//
// All passwords are SYNTHETIC (never real user secrets), so the fixture lives in
// the repo. Regenerate with: go run ./cmd/bcrypt_gold  (writes zig-server/
// bcrypt_gold.jsonl). Regeneration reshuffles the salts; that's expected — it's
// a fixture you re-commit on purpose, not a stable snapshot.
//
// DefaultCost (10) matches server/users.SetUserPassword, so the stored cost
// factor in the fixture mirrors production.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

type goldCase struct {
	ID       string `json:"id"`
	Password string `json:"password"`
	Hash     string `json:"hash"`
	Expect   bool   `json:"expect"`
}

// accepts: passwords whose own Go hash must verify true. Mix of the mundane and
// the corners a port is most likely to get wrong (empty, single char, control
// chars, high-bit/unicode, the 72-byte boundary, leading/trailing spaces).
var accepts = []struct{ id, pw string }{
	{"plain", "correct horse battery staple"},
	{"symbols", "p@ssw0rd! #2026"},
	{"single", "a"},
	{"empty", ""},
	{"spaces", "  leading and trailing  "},
	{"controls", "tab\tand\nnewline"},
	{"unicode", "café ☕ 日本語 π"}, // high-bit bytes: the historical $2a sign-bug edge
	{"boundary72", strings.Repeat("x", 72)},
}

func main() {
	dir := "zig-server"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	path := dir + "/bcrypt_gold.jsonl"

	var cases []goldCase
	for _, a := range accepts {
		h, err := bcrypt.GenerateFromPassword([]byte(a.pw), bcrypt.DefaultCost)
		if err != nil {
			fmt.Fprintf(os.Stderr, "hash %q: %v\n", a.id, err)
			os.Exit(1)
		}
		// the correct password must verify
		cases = append(cases, goldCase{ID: "accept/" + a.id, Password: a.pw, Hash: string(h), Expect: true})
		// a tampered password against the SAME hash must be rejected
		cases = append(cases, goldCase{ID: "reject/" + a.id, Password: a.pw + "X", Hash: string(h), Expect: false})
	}

	f, err := os.Create(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	for _, c := range cases {
		if err := enc.Encode(c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	fmt.Fprintf(os.Stderr, "wrote %d cases to %s\n", len(cases), path)
}
