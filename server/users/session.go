// Authenticated chat sessions. A member who proves their password gets a
// signed cookie (gopher_auth = base64(id).issued.HMAC) — stateless, so
// it works across devices with no session store, and a member's identity
// can't be forged by editing the plaintext gopher_uid cookie. The HMAC
// secret is generated once and persisted at {chat}/_session_secret
// (mode 0600, never in git) so sessions survive restarts.
package users

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const authCookieName = "gopher_auth"
const sessionMaxAge = 365 * 24 * time.Hour

var (
	sessionSecretOnce sync.Once
	sessionSecretVal  []byte
	// sessionSecretDir is where the signing secret is persisted. Set by
	// main via SetSessionSecretDir. Historically this is the chat data
	// dir (sessions were born in chat); kept there so existing sessions
	// stay valid.
	sessionSecretDir string
)

// SetSessionSecretDir tells the session layer where to read/write its
// signing secret. Must be called at startup before any session is signed.
func SetSessionSecretDir(dir string) { sessionSecretDir = dir }

func sessionSecret() []byte {
	sessionSecretOnce.Do(func() {
		path := filepath.Join(sessionSecretDir, "_session_secret")
		if b, err := os.ReadFile(path); err == nil && len(b) >= 32 {
			sessionSecretVal = b
			return
		}
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			panic("session secret: " + err.Error())
		}
		_ = os.MkdirAll(sessionSecretDir, 0o755)
		_ = os.WriteFile(path, secret, 0o600)
		sessionSecretVal = secret
	})
	return sessionSecretVal
}

// sessionMaxAgeSecs is sessionMaxAge in whole seconds — the unit the
// stateless cookie compares against (issued is a Unix-seconds string).
const sessionMaxAgeSecs = int64(sessionMaxAge / time.Second)

// macWith is the raw HMAC step, parameterized by secret so the same code
// signs in production (with sessionSecret) and cross-validates against the
// zig port (with a synthetic secret) — no re-implementation.
func macWith(secret []byte, id, issued string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(id + "\n" + issued))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// SignSessionWith builds a cookie value for id issued at issuedUnix, signed
// with secret. Exported as the cross-validation oracle (the zig port must
// verify these); production calls signSession, which injects the live secret
// and the current time.
func SignSessionWith(secret []byte, id string, issuedUnix int64) string {
	issued := strconv.FormatInt(issuedUnix, 10)
	return base64.RawURLEncoding.EncodeToString([]byte(id)) + "." + issued + "." + macWith(secret, id, issued)
}

// VerifySessionWith returns the id from a cookie value if its signature
// matches secret and it hasn't expired as of nowUnix. The pure core of
// verifySession — exported so the cross-validation harness drives the REAL
// verifier, not a copy.
func VerifySessionWith(secret []byte, val string, nowUnix int64) (string, bool) {
	parts := strings.Split(val, ".")
	if len(parts) != 3 {
		return "", false
	}
	idBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", false
	}
	id, issued := string(idBytes), parts[1]
	if !hmac.Equal([]byte(macWith(secret, id, issued)), []byte(parts[2])) {
		return "", false
	}
	if n, err := strconv.ParseInt(issued, 10, 64); err != nil || nowUnix-n > sessionMaxAgeSecs {
		return "", false
	}
	return id, true
}

func signSession(id string) string {
	return SignSessionWith(sessionSecret(), id, time.Now().Unix())
}

// verifySession returns the user id from a session cookie value if its
// signature is valid and it hasn't expired.
func verifySession(val string) (string, bool) {
	return VerifySessionWith(sessionSecret(), val, time.Now().Unix())
}

// SessionUser returns the authenticated member's id, if the request
// carries a valid session cookie and that id is still a member.
func SessionUser(r *http.Request) (string, bool) {
	c, err := r.Cookie(authCookieName)
	if err != nil {
		return "", false
	}
	id, ok := verifySession(c.Value)
	if !ok || !UserIsMember(id) {
		return "", false
	}
	return id, true
}

// IsAuthorized reports whether the request acts as a real principal —
// either a password member via a session cookie (browser) or any
// authorized principal (member or agent) via a valid API key (bot).
func IsAuthorized(r *http.Request) bool {
	if _, ok := SessionUser(r); ok {
		return true
	}
	_, ok := apiKeyUser(r)
	return ok
}

// SetAuthCookie issues a member session cookie for the given user id.
func SetAuthCookie(w http.ResponseWriter, id string) {
	http.SetCookie(w, &http.Cookie{
		Name:     authCookieName,
		Value:    signSession(id),
		Path:     "/",
		MaxAge:   int(sessionMaxAge / time.Second),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

// ClearAuthCookie removes the member session cookie.
func ClearAuthCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: authCookieName, Value: "", Path: "/", MaxAge: -1,
		HttpOnly: true, SameSite: http.SameSiteLaxMode,
	})
}
