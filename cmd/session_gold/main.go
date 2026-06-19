// session_gold generates the cross-validation fixture for the zig port's
// session-cookie verifier. It signs cookies with the REAL Go signer
// (users.SignSessionWith) using a SYNTHETIC secret, and records the verdict the
// zig verifier (check_session.zig) must reproduce for each.
//
// This is direction 1 — Go signs, zig verifies — the production-critical case:
// every member's live browser cookie was signed by this exact Go code, so the
// zig server must accept them unchanged (read-only identity). Like bcrypt, the
// signature is noise with no eyeball backstop, so this verification TABLE is the
// only instrument that can tell a correct HMAC verify from a broken one.
//
// Unlike bcrypt (salted), session signing is deterministic given (secret, id,
// issued), so this fixture is STABLE — re-running produces identical bytes. The
// secret is synthetic (never the live _session_secret), so the fixture is
// repo-safe. Each row carries its own secret + now so expiry and wrong-secret
// cases are self-contained.
//
// Regenerate: go run ./cmd/session_gold   (writes zig-server/session_gold.jsonl)
package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"angry-gopher/server/users"
)

// row mirrors check_session.zig's Case: verify(secret, cookie, now) must == expect.
type row struct {
	ID     string `json:"id"`     // label for failures
	Secret string `json:"secret"` // hex-encoded HMAC key the zig side verifies with
	Cookie string `json:"cookie"` // the cookie value to verify
	Now    int64  `json:"now"`    // Unix seconds "now" for the expiry check
	Expect string `json:"expect"` // resolved id, or "" if the cookie must be rejected
}

// two distinct synthetic 32-byte secrets (never the live secret).
var (
	secretA = []byte("zig-port synthetic secret AAAAAA")
	secretB = []byte("zig-port synthetic secret BBBBBB")
)

// T0 is a fixed base "issued" time; maxAge is the cookie's lifetime in seconds.
const (
	t0     = int64(1_700_000_000) // 2023-11-14
	maxAge = int64(365 * 24 * 60 * 60)
)

func main() {
	dir := "zig-server"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	path := dir + "/session_gold.jsonl"

	hexA := hex.EncodeToString(secretA)
	hexB := hex.EncodeToString(secretB)

	var rows []row
	add := func(id, secretHex, cookie string, now int64, expect string) {
		rows = append(rows, row{ID: id, Secret: secretHex, Cookie: cookie, Now: now, Expect: expect})
	}

	// Accept: real Go-signed cookies, verified fresh, must resolve to their id.
	for _, uid := range []string{"1", "3", "42", "1234567890"} {
		c := users.SignSessionWith(secretA, uid, t0)
		add("accept/"+uid, hexA, c, t0, uid)                 // now == issued
		add("accept-maxage/"+uid, hexA, c, t0+maxAge, uid)   // exactly at the limit (not expired)
		add("expired/"+uid, hexA, c, t0+maxAge+1, "")        // one second past -> rejected
	}

	// Wrong secret: cookie signed with A, verified with B -> rejected.
	cWrong := users.SignSessionWith(secretA, "7", t0)
	add("wrong-secret", hexB, cWrong, t0, "")

	// Tampered MAC: flip the last byte of a valid cookie -> rejected.
	cTamper := users.SignSessionWith(secretA, "9", t0)
	add("tampered-mac", hexA, flipLast(cTamper), t0, "")

	// Tampered id: re-encode a different id with the original MAC -> rejected.
	// (SignSessionWith for id "9" then swap the id segment for id "8"'s encoding.)
	cId8 := users.SignSessionWith(secretA, "8", t0)
	mac9 := lastSegment(cTamper)
	id8seg := firstSegment(cId8)
	add("tampered-id", hexA, id8seg+"."+middleSegment(cTamper)+"."+mac9, t0, "")

	// Malformed structures -> rejected.
	add("malformed-2parts", hexA, "YQ.1700000000", t0, "")
	add("malformed-4parts", hexA, users.SignSessionWith(secretA, "5", t0)+".extra", t0, "")
	add("malformed-badb64-id", hexA, "!!!."+middleSegment(cTamper)+"."+mac9, t0, "")
	add("malformed-empty", hexA, "", t0, "")

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
	for _, r := range rows {
		if err := enc.Encode(r); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	fmt.Fprintf(os.Stderr, "wrote %d cases to %s\n", len(rows), path)
}

func flipLast(s string) string {
	b := []byte(s)
	if len(b) == 0 {
		return s
	}
	if b[len(b)-1] == 'A' {
		b[len(b)-1] = 'B'
	} else {
		b[len(b)-1] = 'A'
	}
	return string(b)
}

// segment helpers operate on the `id.issued.mac` cookie shape.
func firstSegment(s string) string  { return splitN(s)[0] }
func middleSegment(s string) string { return splitN(s)[1] }
func lastSegment(s string) string   { return splitN(s)[2] }
func splitN(s string) [3]string {
	var out [3]string
	i := 0
	start := 0
	for j := 0; j < len(s) && i < 3; j++ {
		if s[j] == '.' {
			out[i] = s[start:j]
			i++
			start = j + 1
		}
	}
	if i < 3 {
		out[i] = s[start:]
	}
	return out
}
