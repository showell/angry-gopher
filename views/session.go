// Authenticated chat sessions. A member who proves their password gets a
// signed cookie (gopher_auth = base64(name).issued.HMAC) — stateless, so
// it works across devices with no session store, and a member's identity
// can't be forged by editing the plaintext gopher_user cookie. The HMAC
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

func signSession(name string) string {
	issued := strconv.FormatInt(time.Now().Unix(), 10)
	return base64.RawURLEncoding.EncodeToString([]byte(name)) + "." + issued + "." + sessionMAC(name, issued)
}

// verifySession returns the name from a session cookie value if its
// signature is valid and it hasn't expired.
func verifySession(val string) (string, bool) {
	parts := strings.Split(val, ".")
	if len(parts) != 3 {
		return "", false
	}
	nameBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", false
	}
	name, issued := string(nameBytes), parts[1]
	if !hmac.Equal([]byte(sessionMAC(name, issued)), []byte(parts[2])) {
		return "", false
	}
	if n, err := strconv.ParseInt(issued, 10, 64); err != nil || time.Since(time.Unix(n, 0)) > sessionMaxAge {
		return "", false
	}
	return name, true
}

// SessionUser returns the authenticated member name, if the request
// carries a valid session cookie and that name is still a member.
func SessionUser(r *http.Request) (string, bool) {
	c, err := r.Cookie(authCookieName)
	if err != nil {
		return "", false
	}
	name, ok := verifySession(c.Value)
	if !ok || !IsReserved(name) {
		return "", false
	}
	return name, true
}

// IsMember reports whether the request is an authenticated member.
func IsMember(r *http.Request) bool {
	_, ok := SessionUser(r)
	return ok
}

// SetAuthCookie issues a member session cookie.
func SetAuthCookie(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{
		Name:     authCookieName,
		Value:    signSession(name),
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
