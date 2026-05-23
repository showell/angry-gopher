// API keys: a member can hold one bot key for programmatic, READ-ONLY
// access to their own data (the dogfooded chat API). The key is
// "<id>-<secret>" (secret = 32 hex from crypto/rand). We store only
// sha256(key) — a leak of the users tree doesn't expose live keys — and
// embedding the id makes lookup O(1): parse the id, load that user's
// hash, constant-time compare (no scan, no index).
//
// Auth flow: a request carries the key as `Authorization: Bearer <key>`.
// CurrentUser resolves it to the member (with admin stripped — a key is
// never an admin credential), and the login gate enforces read-only by
// rejecting any non-GET request that authenticated via a key.
package views

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
)

func apiKeyHashFile(id string) string { return userFile(id, "api-key") }

// SetUserAPIKey generates a fresh key for a member, stores its hash, and
// returns the plaintext key ONCE — it can't be recovered afterward.
func SetUserAPIKey(id string) (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	key := id + "-" + hex.EncodeToString(b[:])
	sum := sha256.Sum256([]byte(key))
	if err := os.WriteFile(apiKeyHashFile(id), []byte(hex.EncodeToString(sum[:])), 0o600); err != nil {
		return "", err
	}
	return key, nil
}

// UserHasAPIKey reports whether a member has an API key.
func UserHasAPIKey(id string) bool {
	_, err := os.Stat(apiKeyHashFile(id))
	return err == nil
}

// ClearUserAPIKey revokes a member's API key.
func ClearUserAPIKey(id string) error {
	if err := os.Remove(apiKeyHashFile(id)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// CheckAPIKey resolves the member id a presented key belongs to, or
// ok=false. Constant-time compare against the stored hash.
func CheckAPIKey(presented string) (string, bool) {
	id, _, found := strings.Cut(presented, "-")
	if !found || id == "" || !UserIsMember(id) {
		return "", false
	}
	stored, err := os.ReadFile(apiKeyHashFile(id))
	if err != nil {
		return "", false
	}
	sum := sha256.Sum256([]byte(presented))
	want := hex.EncodeToString(sum[:])
	if subtle.ConstantTimeCompare([]byte(want), stored) == 1 {
		return id, true
	}
	return "", false
}

// bearerToken extracts the token from an `Authorization: Bearer <token>`
// header (empty if absent).
func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}

// apiKeyUser resolves the member id a request authenticates as via its
// API key header, if any.
func apiKeyUser(r *http.Request) (string, bool) {
	key := bearerToken(r)
	if key == "" {
		return "", false
	}
	return CheckAPIKey(key)
}

// IsAPIKeyAuth reports whether the request authenticated via a valid API
// key. The login gate uses this to enforce read-only (key requests may
// only GET).
func IsAPIKeyAuth(r *http.Request) bool {
	_, ok := apiKeyUser(r)
	return ok
}
