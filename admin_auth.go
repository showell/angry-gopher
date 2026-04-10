// Admin authentication: session cookies and login page.

package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"

	"angry-gopher/auth"
)

var sessionKey []byte

func init() {
	sessionKey = make([]byte, 32)
	rand.Read(sessionKey)
}

func signSession(userID int) string {
	payload := strconv.Itoa(userID)
	mac := hmac.New(sha256.New, sessionKey)
	mac.Write([]byte(payload))
	sig := hex.EncodeToString(mac.Sum(nil))
	return payload + "." + sig
}

func verifySession(cookie string) int {
	parts := strings.SplitN(cookie, ".", 2)
	if len(parts) != 2 {
		return 0
	}
	userID, err := strconv.Atoi(parts[0])
	if err != nil || userID == 0 {
		return 0
	}
	mac := hmac.New(sha256.New, sessionKey)
	mac.Write([]byte(parts[0]))
	expected := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(parts[1]), []byte(expected)) {
		return 0
	}
	return userID
}

func authenticateAdmin(r *http.Request) int {
	if c, err := r.Cookie("gopher_admin"); err == nil {
		if userID := verifySession(c.Value); userID != 0 && auth.IsAdmin(userID) {
			return userID
		}
	}
	userID := auth.Authenticate(r)
	if userID != 0 && auth.IsAdmin(userID) {
		return userID
	}
	return 0
}

func handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		r.ParseForm()
		email := r.FormValue("email")
		apiKey := r.FormValue("api_key")

		var userID int
		err := DB.QueryRow(`SELECT id FROM users WHERE email = ? AND api_key = ? AND is_admin = 1`,
			email, apiKey).Scan(&userID)
		if err != nil || userID == 0 {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, adminLoginPage("Invalid credentials or not an admin."))
			return
		}

		http.SetCookie(w, &http.Cookie{
			Name:     "gopher_admin",
			Value:    signSession(userID),
			Path:     "/admin/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
		http.Redirect(w, r, "/admin/", http.StatusSeeOther)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, adminLoginPage(""))
}

func adminLoginPage(errMsg string) string {
	errorHTML := ""
	if errMsg != "" {
		errorHTML = fmt.Sprintf(`<p style="color:red;font-weight:bold">%s</p>`, html.EscapeString(errMsg))
	}
	return fmt.Sprintf(`<!DOCTYPE html>
<html><head><title>Admin Login — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 400px; }
h1 { color: #000080; }
label { display: block; margin-top: 12px; font-weight: bold; }
input { width: 100%%; padding: 6px; margin-top: 4px; font-size: 14px; box-sizing: border-box; }
button { margin-top: 16px; padding: 8px 20px; font-size: 14px; background: #000080; color: white; border: none; cursor: pointer; border-radius: 4px; }
</style>
</head><body>
<h1>Admin Login</h1>
%s
<form method="POST">
<label>Email<input type="email" name="email" required autofocus></label>
<label>API Key<input type="password" name="api_key" required></label>
<button type="submit">Log in</button>
</form>
</body></html>`, errorHTML)
}
