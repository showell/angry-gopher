// Command health_check queries a running Angry Gopher server and
// reports potential problems. Designed for quick triage — run this
// when something seems off.
//
// Usage:
//
//	go run ./cmd/health_check
//	go run ./cmd/health_check -url http://localhost:9000
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

type healthData struct {
	Queues       []queueInfo  `json:"queues"`
	OnlineUsers  int          `json:"online_users"`
	Rejected429s int          `json:"rejected_429s"`
	RLUsers      []rlUserInfo `json:"rate_limit_users"`
	RLMax        int          `json:"rate_limit_max"`
}

type queueInfo struct {
	ID      string `json:"id"`
	UserID  int    `json:"user_id"`
	Pending int    `json:"pending"`
	LastID  int    `json:"last_id"`
}

type rlUserInfo struct {
	UserID   int `json:"user_id"`
	Requests int `json:"requests"`
	Headroom int `json:"headroom"`
}

func main() {
	baseURL := flag.String("url", "http://localhost:9002", "server base URL")
	email := flag.String("email", "claude@example.com", "admin email")
	apiKey := flag.String("api-key", "claude-api-key", "admin API key")
	flag.Parse()

	client := &http.Client{Timeout: 5 * time.Second}
	req, _ := http.NewRequest("GET", *baseURL+"/admin/health", nil)
	creds := base64.StdEncoding.EncodeToString([]byte(*email + ":" + *apiKey))
	req.Header.Set("Authorization", "Basic "+creds)
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: cannot reach server at %s: %v\n", *baseURL, err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		fmt.Fprintf(os.Stderr, "FAIL: server returned %d: %s\n", resp.StatusCode, body)
		os.Exit(1)
	}

	var data healthData
	if err := json.Unmarshal(body, &data); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: bad response: %v\n", err)
		os.Exit(1)
	}

	problems := 0

	// Check for orphaned or bloated queues.
	for _, q := range data.Queues {
		if q.Pending > 500 {
			fmt.Printf("WARN: queue %s (user %d) has %d pending events — likely orphaned or stuck\n",
				q.ID, q.UserID, q.Pending)
			problems++
		} else if q.Pending > 100 {
			fmt.Printf("NOTE: queue %s (user %d) has %d pending events\n",
				q.ID, q.UserID, q.Pending)
		}
	}

	// Check rate limiting pressure.
	if data.Rejected429s > 0 {
		fmt.Printf("NOTE: %d requests have been rate-limited (429s)\n", data.Rejected429s)
	}
	for _, u := range data.RLUsers {
		if u.Headroom <= 0 {
			fmt.Printf("WARN: user %d is at rate limit (%d/%d requests)\n",
				u.UserID, u.Requests, data.RLMax)
			problems++
		} else if u.Headroom < 20 {
			fmt.Printf("NOTE: user %d is near rate limit (%d/%d, headroom %d)\n",
				u.UserID, u.Requests, data.RLMax, u.Headroom)
		}
	}

	// Summary.
	fmt.Printf("\n--- Health Summary ---\n")
	fmt.Printf("  Queues:       %d\n", len(data.Queues))
	fmt.Printf("  Online users: %d\n", data.OnlineUsers)
	fmt.Printf("  429s total:   %d\n", data.Rejected429s)
	if problems == 0 {
		fmt.Printf("  Status:       OK\n")
	} else {
		fmt.Printf("  Status:       %d problem(s) found\n", problems)
	}
}
