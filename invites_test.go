// Tests for the invite system: create, redeem, expiry, and permissions.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/auth"
	"angry-gopher/invites"
)

func createInvite(t *testing.T, email, fullName string) string {
	t.Helper()
	form := url.Values{}
	form.Set("email", email)
	form.Set("full_name", fullName)

	req := httptest.NewRequest("POST", "/gopher/invites", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req) // Steve is admin
	rec := httptest.NewRecorder()
	invites.HandleCreateInvite(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("failed to create invite: %v", body["msg"])
	}
	return body["token"].(string)
}

func redeemInvite(t *testing.T, token string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("token", token)

	req := httptest.NewRequest("POST", "/gopher/invites/redeem", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	invites.HandleRedeemInvite(rec, req)
	return rec
}

func TestCreateAndRedeemInvite(t *testing.T) {
	resetDB()

	token := createInvite(t, "mom@example.com", "Mom")

	rec := redeemInvite(t, token)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}
	if body["email"] != "mom@example.com" {
		t.Errorf("expected mom's email, got %v", body["email"])
	}
	if body["full_name"] != "Mom" {
		t.Errorf("expected Mom, got %v", body["full_name"])
	}
	if body["api_key"] == nil || body["api_key"] == "" {
		t.Error("expected a generated API key")
	}

	// Mom should be subscribed to ChitChat (public) but not private channels.
	userID := int(body["user_id"].(float64))
	var subCount int
	DB.QueryRow(`SELECT COUNT(*) FROM subscriptions WHERE user_id = ?`, userID).Scan(&subCount)
	if subCount != 1 {
		t.Errorf("Mom should be subscribed to 1 public channel, got %d", subCount)
	}
}

func TestInviteTokenIsSingleUse(t *testing.T) {
	resetDB()

	token := createInvite(t, "mom@example.com", "Mom")
	redeemInvite(t, token)

	// Second redemption should fail.
	rec := redeemInvite(t, token)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error on second redemption, got %v", body["result"])
	}
}

func TestInviteRequiresAdmin(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("email", "mom@example.com")
	form.Set("full_name", "Mom")

	req := httptest.NewRequest("POST", "/gopher/invites", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req) // Joe is not admin
	rec := httptest.NewRecorder()
	invites.HandleCreateInvite(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("non-admin should not be able to create invites, got %v", body["result"])
	}
}

func TestInvalidTokenRejected(t *testing.T) {
	resetDB()

	rec := redeemInvite(t, "bogus-token")
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for invalid token, got %v", body["result"])
	}
}

func TestDuplicateEmailRejected(t *testing.T) {
	resetDB()

	// steve@example.com already exists in seed data.
	form := url.Values{}
	form.Set("email", "steve@example.com")
	form.Set("full_name", "Duplicate Steve")

	req := httptest.NewRequest("POST", "/gopher/invites", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	invites.HandleCreateInvite(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for duplicate email, got %v", body["result"])
	}
}

func TestRedeemedUserCanAuthenticate(t *testing.T) {
	resetDB()

	token := createInvite(t, "mom@example.com", "Mom")
	rec := redeemInvite(t, token)
	body := parseJSON(t, rec)

	email := body["email"].(string)
	apiKey := body["api_key"].(string)

	// Mom should be able to authenticate.
	req := httptest.NewRequest("GET", "/", nil)
	setAuth(req, email, apiKey)

	userID := auth.Authenticate(req)
	if userID == 0 {
		t.Error("Mom should be able to authenticate with her new credentials")
	}
}
