// API keys: any authorized principal (a password member OR an agent) can
// hold one bot key for programmatic access to their own data (the
// dogfooded chat API). The key acts as the principal — it can read AND
// write on their behalf (post messages, upload), just like a password —
// but it is NOT an admin credential (CurrentUser strips Admin), so a key
// can never reach the /admin panel. For agents (no password), the API
// key is the only credential and must be treated as such. Treat it like
// a password.
// The key is "<id>-<secret>" (secret = 32 hex from crypto/rand). We store
// it in plaintext so the member can view it again (Settings → Show key);
// this adds ~no marginal risk — anyone who could read the key file already
// has the data dir. Embedding the id makes lookup O(1): parse the id, load
// that user's key, constant-time compare (no scan, no index). Legacy keys
// stored as a bare sha256 hash (no "-") still authenticate but can't be
// shown — regenerate to view.
//
// Auth flow: a request carries the key as `Authorization: Bearer <key>`;
// CurrentUser resolves it to the member (admin stripped).
package users

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
)

// The api key is account data — it lives in the shared AuthRoot (alongside
// name + password), not the gopher-private user dir.
func apiKeyFile(id string) string { return authFile(id, "api-key") }

// SetUserAPIKey generates a fresh key for a member, stores it (plaintext),
// and returns it.
func SetUserAPIKey(id string) (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	key := id + "-" + hex.EncodeToString(b[:])
	_ = os.MkdirAll(authDir(id), 0o755)
	if err := os.WriteFile(apiKeyFile(id), []byte(key), 0o600); err != nil {
		return "", err
	}
	return key, nil
}

// UserHasAPIKey reports whether a member has an API key.
func UserHasAPIKey(id string) bool {
	_, err := os.Stat(apiKeyFile(id))
	return err == nil
}

// GetUserAPIKey returns a member's stored key for display, ok=false if
// there's none or it's a legacy hash (no "-") that can't be shown.
func GetUserAPIKey(id string) (string, bool) {
	b, err := os.ReadFile(apiKeyFile(id))
	if err != nil {
		return "", false
	}
	key := strings.TrimSpace(string(b))
	if !strings.Contains(key, "-") {
		return "", false // legacy hashed key — not recoverable
	}
	return key, true
}

// ClearUserAPIKey revokes a member's API key.
func ClearUserAPIKey(id string) error {
	if err := os.Remove(apiKeyFile(id)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// CheckAPIKey resolves the member id a presented key belongs to, or
// ok=false. Plaintext keys (with "-") compare directly; legacy keys stored
// as a bare sha256 hash compare against sha256(presented). Constant-time.
func CheckAPIKey(presented string) (string, bool) {
	id, _, found := strings.Cut(presented, "-")
	if !found || id == "" || !UserIsAuthorized(id) {
		return "", false
	}
	b, err := os.ReadFile(apiKeyFile(id))
	if err != nil {
		return "", false
	}
	stored := strings.TrimSpace(string(b))
	var ok bool
	if strings.Contains(stored, "-") {
		ok = subtle.ConstantTimeCompare([]byte(stored), []byte(presented)) == 1
	} else {
		sum := sha256.Sum256([]byte(presented))
		ok = subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(stored)) == 1
	}
	if ok {
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
