// Authenticated chat sessions. A member who proves their password gets a
// signed cookie (gopher_auth = base64(name).issued.HMAC) — stateless, so
// it works across devices with no session store, and a member's identity
// can't be forged by editing the plaintext gopher_uid cookie. The HMAC
// secret is generated once and persisted at {chat}/_session_secret
// (mode 0600, never in git) so sessions survive restarts.
package views

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
)

func sessionSecret() []byte {
	sessionSecretOnce.Do(func() {
		path := filepath.Join(ChatDataRoot, "_session_secret")
		if b, err := os.ReadFile(path); err == nil && len(b) >= 32 {
			sessionSecretVal = b
			return
		}
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			panic("chat session secret: " + err.Error())
		}
		_ = os.MkdirAll(ChatDataRoot, 0o755)
		_ = os.WriteFile(path, secret, 0o600)
		sessionSecretVal = secret
	})
	return sessionSecretVal
}

func sessionMAC(name, issued string) string {
	mac := hmac.New(sha256.New, sessionSecret())
	mac.Write([]byte(name + "\n" + issued))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func signSession(id string) string {
	issued := strconv.FormatInt(time.Now().Unix(), 10)
	return base64.RawURLEncoding.EncodeToString([]byte(id)) + "." + issued + "." + sessionMAC(id, issued)
}

// verifySession returns the user id from a session cookie value if its
// signature is valid and it hasn't expired.
func verifySession(val string) (string, bool) {
	parts := strings.Split(val, ".")
	if len(parts) != 3 {
		return "", false
	}
	idBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", false
	}
	id, issued := string(idBytes), parts[1]
	if !hmac.Equal([]byte(sessionMAC(id, issued)), []byte(parts[2])) {
		return "", false
	}
	if n, err := strconv.ParseInt(issued, 10, 64); err != nil || time.Since(time.Unix(n, 0)) > sessionMaxAge {
		return "", false
	}
	return id, true
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

// IsMember reports whether the request is an authenticated member — by a
// session cookie (browser) or a valid API key (bot, read-only).
func IsMember(r *http.Request) bool {
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
