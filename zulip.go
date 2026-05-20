// Zulip notifications: a small stream message when a player logs in.
//
// Convention (matches the prior LynRummy client): POST to
// {url}/api/v1/messages with HTTP Basic auth (email:api_key) and a
// form body of type=stream, to=<stream>, topic, content.

package main

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// loginDebounce suppresses repeat pings for the same name within the
// window — a reload or re-login shouldn't spam the channel.
const loginDebounce = time.Hour

var (
	lastLoginMu     sync.Mutex
	lastLoginNotify = map[string]time.Time{}
)

// notifyLogin sends a Zulip stream message that `name` logged in,
// unless one was sent for that name within loginDebounce. It is meant
// to be called in a goroutine; failures are logged, never surfaced to
// the player. A no-op if Zulip isn't configured.
func notifyLogin(name string) {
	cfg := serverConfig
	if cfg == nil || cfg.ZulipURL == "" || cfg.ZulipAPIKey == "" || cfg.ZulipStream == "" {
		return
	}

	lastLoginMu.Lock()
	if t, ok := lastLoginNotify[name]; ok && time.Since(t) < loginDebounce {
		lastLoginMu.Unlock()
		return
	}
	lastLoginNotify[name] = time.Now()
	lastLoginMu.Unlock()

	topic := cfg.ZulipTopic
	if topic == "" {
		topic = "logins"
	}

	form := url.Values{
		"type":    {"stream"},
		"to":      {cfg.ZulipStream},
		"topic":   {topic},
		"content": {fmt.Sprintf("**%s** logged in to Lyn Rummy.", name)},
	}

	req, err := http.NewRequest(
		http.MethodPost,
		strings.TrimRight(cfg.ZulipURL, "/")+"/api/v1/messages",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		log.Printf("zulip: build request: %v", err)
		return
	}
	req.SetBasicAuth(cfg.ZulipEmail, cfg.ZulipAPIKey)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("zulip: post message: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("zulip: unexpected status %d", resp.StatusCode)
	}
}
