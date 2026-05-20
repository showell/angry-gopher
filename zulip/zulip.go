// Package zulip sends small operational notifications to a Zulip
// stream: a player login, or an over-limit write attempt. Configured
// once at startup; both the login handler and the write handlers use
// it. Best-effort and debounced — a flood produces one message, and
// a failed send is logged, never surfaced to a player.
//
// Convention (matches the prior LynRummy client): POST to
// {url}/api/v1/messages with HTTP Basic auth (email:api_key) and a
// form body of type=stream, to=<stream>, topic, content.
package zulip

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Config carries the Zulip bot credentials and destination.
type Config struct {
	URL    string
	Email  string
	APIKey string
	Stream string
	Topic  string
}

var cfg Config

// Configure wires the credentials/destination. Called once at startup.
func Configure(c Config) { cfg = c }

func enabled() bool {
	return cfg.URL != "" && cfg.APIKey != "" && cfg.Stream != ""
}

func topic() string {
	if cfg.Topic != "" {
		return cfg.Topic
	}
	return "logins"
}

// debounceWindow suppresses repeat messages with the same key.
const debounceWindow = time.Hour

var (
	mu       sync.Mutex
	lastSent = map[string]time.Time{}
)

func debounced(key string) bool {
	mu.Lock()
	defer mu.Unlock()
	if t, ok := lastSent[key]; ok && time.Since(t) < debounceWindow {
		return false
	}
	lastSent[key] = time.Now()
	return true
}

// NotifyLogin announces a player login (debounced per name). Intended
// to be called in a goroutine.
func NotifyLogin(name string) {
	if !enabled() || !debounced("login:"+name) {
		return
	}
	send(fmt.Sprintf("**%s** logged in to Lyn Rummy.", name))
}

// NotifyOverLimit alerts that a player's write was rejected for
// exceeding the size limit, with enough detail to start investigating
// (debounced per name). Intended to be called in a goroutine.
func NotifyOverLimit(name string, bytes int64, sessions int) {
	if !enabled() || !debounced("overlimit:"+name) {
		return
	}
	send(fmt.Sprintf(
		"⚠️ **%s** hit the upload size limit — a write was rejected. "+
			"They currently hold %s (%d bytes) across %d sessions. "+
			"Logging on to investigate.",
		name, humanBytes(bytes), bytes, sessions))
}

// send posts one stream message. No-op if unconfigured.
func send(content string) {
	if !enabled() {
		return
	}
	form := url.Values{
		"type":    {"stream"},
		"to":      {cfg.Stream},
		"topic":   {topic()},
		"content": {content},
	}
	req, err := http.NewRequest(
		http.MethodPost,
		strings.TrimRight(cfg.URL, "/")+"/api/v1/messages",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		log.Printf("zulip: build request: %v", err)
		return
	}
	req.SetBasicAuth(cfg.Email, cfg.APIKey)
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

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
}
