// Command stress runs realistic bot clients against a live Angry
// Gopher server. Each bot registers an event queue, polls for
// events in a background goroutine, sends presence heartbeats,
// and periodically sends messages, edits them, and adds reactions.
//
// Usage:
//
//	go run ./cmd/stress                            # 4 bots, stress server
//	go run ./cmd/stress -seed 500                  # seed 500 messages first
//	go run ./cmd/stress -url http://localhost:9001  # point at demo
//	go run ./cmd/stress -bots 2                    # fewer bots
//
// The bots run until interrupted (Ctrl-C). Watch the ops dashboard
// at /admin/ops to see queues, presence, and rate limit stats.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"
)

// Bot credentials must match what seedData() inserts.
var allBots = []botConfig{
	{name: "Steve", email: "steve@example.com", apiKey: "steve-api-key"},
	{name: "Apoorva", email: "apoorva@example.com", apiKey: "apoorva-api-key"},
	{name: "Claude", email: "claude@example.com", apiKey: "claude-api-key"},
	{name: "Joe", email: "joe@example.com", apiKey: "joe-api-key"},
}

type botConfig struct {
	name   string
	email  string
	apiKey string
}

// bot is a single simulated client with its own event queue and
// activity loop.
type bot struct {
	cfg      botConfig
	baseURL  string
	channels []string // channel IDs this bot can post to
	queueID  string
	lastEvID int
	msgsSent int
	evtsRecv int
	mu       sync.Mutex // protects stats
}

func main() {
	baseURL := flag.String("url", "http://localhost:9002", "server base URL")
	numBots := flag.Int("bots", 4, "number of bots to run (1-4)")
	seedCount := flag.Int("seed", 0, "generate N messages as warmup before starting bots")
	flag.Parse()

	if *numBots < 1 || *numBots > len(allBots) {
		log.Fatalf("bots must be between 1 and %d", len(allBots))
	}

	// Set up bots first (fetch channels + register queues) while the
	// rate limiter is clear, then seed, then start the loops.
	bots := make([]*bot, *numBots)
	for i := 0; i < *numBots; i++ {
		b := &bot{
			cfg:     allBots[i],
			baseURL: *baseURL,
		}
		bots[i] = b

		if !b.fetchChannels() {
			log.Fatalf("[%s] failed to fetch channels — is the server running at %s?", b.cfg.name, *baseURL)
		}
		if !b.register() {
			log.Fatalf("[%s] failed to register queue — is the server running at %s?", b.cfg.name, *baseURL)
		}
		log.Printf("[%s] registered queue %s (channels: %v)", b.cfg.name, b.queueID, b.channels)
	}

	if *seedCount > 0 {
		seedMessages(*baseURL, bots, *seedCount)
	}

	// Ctrl-C to stop.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	done := make(chan struct{})

	var wg sync.WaitGroup
	for _, b := range bots {
		wg.Add(2)
		go func() { defer wg.Done(); b.pollLoop(done) }()
		go func() { defer wg.Done(); b.activityLoop(done) }()
	}

	log.Printf("All %d bots running. Press Ctrl-C to stop.", *numBots)
	log.Printf("Watch the dashboard: %s/admin/ops", *baseURL)

	<-stop
	log.Println("Shutting down...")
	close(done)
	wg.Wait()

	// Print summary.
	fmt.Println("\n=== Summary ===")
	for _, b := range bots {
		b.mu.Lock()
		fmt.Printf("  %-10s  sent: %d messages  received: %d events\n",
			b.cfg.name, b.msgsSent, b.evtsRecv)
		b.mu.Unlock()
	}
}

// fetchChannels queries the server for channels this bot is subscribed to.
func (b *bot) fetchChannels() bool {
	result := b.get("/api/v1/users/me/subscriptions", 10*time.Second)
	if result == nil || result["result"] != "success" {
		return false
	}
	subs, ok := result["subscriptions"].([]interface{})
	if !ok {
		return false
	}
	b.channels = nil
	for _, s := range subs {
		sub := s.(map[string]interface{})
		id := int(sub["stream_id"].(float64))
		b.channels = append(b.channels, fmt.Sprintf("%d", id))
	}
	return len(b.channels) > 0
}

// register creates an event queue on the server.
func (b *bot) register() bool {
	result := b.post("/api/v1/register", nil)
	if result == nil || result["result"] != "success" {
		return false
	}
	b.queueID = result["queue_id"].(string)
	b.lastEvID = int(result["last_event_id"].(float64))
	return true
}

// pollLoop long-polls for events until done is closed.
func (b *bot) pollLoop(done chan struct{}) {
	for {
		select {
		case <-done:
			return
		default:
		}

		path := fmt.Sprintf("/api/v1/events?queue_id=%s&last_event_id=%d",
			b.queueID, b.lastEvID)
		result := b.getWithCancel(path, 55*time.Second, done)

		if result == nil {
			// Timeout or error — just retry.
			continue
		}

		if result["result"] != "success" {
			code, _ := result["code"].(string)
			if code == "BAD_EVENT_QUEUE_ID" {
				log.Printf("[%s] queue expired, re-registering", b.cfg.name)
				if !b.register() {
					log.Printf("[%s] re-register failed, retrying in 5s", b.cfg.name)
					sleepOrDone(done, 5*time.Second)
				}
			}
			continue
		}

		events, ok := result["events"].([]interface{})
		if !ok || len(events) == 0 {
			continue
		}

		// Advance past real events only (skip heartbeats).
		for _, e := range events {
			evt := e.(map[string]interface{})
			if evt["type"] != "heartbeat" {
				id := int(evt["id"].(float64))
				if id > b.lastEvID {
					b.lastEvID = id
				}
			}
		}

		b.mu.Lock()
		b.evtsRecv += len(events)
		b.mu.Unlock()
	}
}

// activityLoop simulates realistic user behavior:
//   - Presence heartbeat every 60 seconds
//   - Send a message every 10-30 seconds
//   - Occasionally edit the last message or add a reaction
func (b *bot) activityLoop(done chan struct{}) {
	// Stagger bot startup so they don't all fire at once.
	sleepOrDone(done, time.Duration(rand.Intn(3000))*time.Millisecond)

	presenceTicker := time.NewTicker(60 * time.Second)
	defer presenceTicker.Stop()

	// Send initial presence immediately.
	b.sendPresence()

	var lastMsgID float64

	for {
		// Random interval between messages: 10-30 seconds.
		msgDelay := time.Duration(10+rand.Intn(20)) * time.Second

		select {
		case <-done:
			return
		case <-presenceTicker.C:
			b.sendPresence()
		case <-time.After(msgDelay):
			// Pick an action weighted toward sending messages.
			action := rand.Intn(10)
			switch {
			case action < 6:
				// Send a message.
				msgID := b.sendMessage()
				if msgID > 0 {
					lastMsgID = msgID
				}
			case action < 8 && lastMsgID > 0:
				// Edit the last message.
				b.editMessage(int(lastMsgID))
			case lastMsgID > 0:
				// Add a reaction.
				b.addReaction(int(lastMsgID))
			default:
				msgID := b.sendMessage()
				if msgID > 0 {
					lastMsgID = msgID
				}
			}
		}
	}
}

// --- Actions ---

func (b *bot) sendPresence() {
	b.post("/api/v1/users/me/presence", url.Values{
		"status": {"active"},
	})
}

var topics = []string{
	"weekly sync", "bug reports", "design review",
	"onboarding", "release planning", "random",
}

var messageTemplates = []string{
	"Has anyone looked at the latest PR?",
	"I think we should revisit the approach here.",
	"LGTM, shipping it.",
	"Can someone review this before EOD?",
	"I'll take a look after lunch.",
	"Just pushed a fix for the flaky test.",
	"The dashboard looks great!",
	"Are we still on track for the release?",
	"I'm seeing some weird behavior in staging.",
	"Let me know if you need help with that.",
}

func (b *bot) sendMessage() float64 {
	topic := topics[rand.Intn(len(topics))]
	content := messageTemplates[rand.Intn(len(messageTemplates))]

	channel := b.channels[rand.Intn(len(b.channels))]

	result := b.post("/api/v1/messages", url.Values{
		"to":      {channel},
		"topic":   {topic},
		"content": {fmt.Sprintf("[%s] %s", b.cfg.name, content)},
		"type":    {"stream"},
	})

	if result != nil && result["result"] == "success" {
		b.mu.Lock()
		b.msgsSent++
		b.mu.Unlock()
		if id, ok := result["id"].(float64); ok {
			return id
		}
	}
	return 0
}

func (b *bot) editMessage(msgID int) {
	edits := []string{
		"(edited) Never mind, I figured it out.",
		"(edited) Updated with more context.",
		"(edited) Fixed the typo.",
	}
	b.patch(fmt.Sprintf("/api/v1/messages/%d", msgID), url.Values{
		"content": {edits[rand.Intn(len(edits))]},
	})
}

var reactions = []struct {
	name string
	code string
}{
	{"thumbs_up", "1f44d"},
	{"heart", "2764"},
	{"laughing", "1f606"},
	{"rocket", "1f680"},
	{"eyes", "1f440"},
}

func (b *bot) addReaction(msgID int) {
	r := reactions[rand.Intn(len(reactions))]
	b.post(fmt.Sprintf("/api/v1/messages/%d/reactions", msgID), url.Values{
		"emoji_name": {r.name},
		"emoji_code": {r.code},
		"reaction_type": {"unicode_emoji"},
	})
}

// --- Seed phase ---

// seedMessages sends N messages through the API, spread across bots,
// channels, and topics to create realistic data volume. This runs
// synchronously before the bot loops start.
func seedMessages(baseURL string, bots []*bot, count int) {
	log.Printf("Seeding %d messages...", count)

	seedTopics := []string{
		"project kickoff", "architecture decisions", "code review",
		"deployment checklist", "bug triage", "sprint planning",
		"documentation", "performance tuning", "security audit",
		"onboarding notes",
	}
	seedBodies := []string{
		"I've been thinking about this and I think we should reconsider the approach.",
		"Here's what I found after investigating: the root cause is in the event loop.",
		"Can we schedule a quick sync on this? I have some concerns.",
		"Pushed a fix. The issue was a race condition in the queue handler.",
		"I tested this locally and it works. Ready for review.",
		"We should add monitoring for this. I'll file a ticket.",
		"Good catch! I missed that edge case. Updating the PR now.",
		"The benchmarks look much better after the optimization.",
		"I think this is ready to ship. Any objections?",
		"Let me look into this more. I'll report back after lunch.",
		"We need to update the docs before the release.",
		"The integration tests are passing now. All green.",
		"I agree with the plan. Let's move forward.",
		"One more thing — we should also handle the timeout case.",
		"Nice work on the refactor. The code is much cleaner now.",
	}

	errors := 0
	for i := 0; i < count; i++ {
		b := bots[i%len(bots)]
		if len(b.channels) == 0 {
			continue
		}
		ch := b.channels[rand.Intn(len(b.channels))]
		topic := seedTopics[rand.Intn(len(seedTopics))]
		body := seedBodies[rand.Intn(len(seedBodies))]

		result := b.post("/api/v1/messages", url.Values{
			"to":      {ch},
			"topic":   {topic},
			"content": {fmt.Sprintf("[%s] %s", b.cfg.name, body)},
			"type":    {"stream"},
		})
		if result == nil || result["result"] != "success" {
			errors++
			if errors == 1 {
				log.Printf("  seed error: %v", result)
			}
		}

		if (i+1)%100 == 0 {
			log.Printf("  seeded %d / %d messages", i+1, count)
		}
	}

	if errors > 0 {
		log.Printf("  seeding complete: %d errors out of %d", errors, count)
	} else {
		log.Printf("  seeded %d messages", count)
	}
}

// --- HTTP helpers ---

func (b *bot) authHeader() string {
	return "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(b.cfg.email+":"+b.cfg.apiKey))
}

func (b *bot) post(path string, params url.Values) map[string]interface{} {
	var body io.Reader
	if params != nil {
		body = strings.NewReader(params.Encode())
	}
	req, _ := http.NewRequest("POST", b.baseURL+path, body)
	if params != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	req.Header.Set("Authorization", b.authHeader())

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)

	var result map[string]interface{}
	json.Unmarshal(data, &result)
	return result
}

func (b *bot) patch(path string, params url.Values) map[string]interface{} {
	req, _ := http.NewRequest("PATCH", b.baseURL+path,
		strings.NewReader(params.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Authorization", b.authHeader())

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)

	var result map[string]interface{}
	json.Unmarshal(data, &result)
	return result
}

func (b *bot) getWithCancel(path string, timeout time.Duration, done chan struct{}) map[string]interface{} {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// Cancel the request immediately when done is closed.
	go func() {
		select {
		case <-done:
			cancel()
		case <-ctx.Done():
		}
	}()
	req, _ := http.NewRequestWithContext(ctx, "GET", b.baseURL+path, nil)
	req.Header.Set("Authorization", b.authHeader())

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)

	var result map[string]interface{}
	json.Unmarshal(data, &result)
	return result
}

func (b *bot) get(path string, timeout time.Duration) map[string]interface{} {
	req, _ := http.NewRequest("GET", b.baseURL+path, nil)
	req.Header.Set("Authorization", b.authHeader())

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)

	var result map[string]interface{}
	json.Unmarshal(data, &result)
	return result
}

// sleepOrDone sleeps for the given duration or returns early if
// done is closed.
func sleepOrDone(done chan struct{}, d time.Duration) {
	select {
	case <-done:
	case <-time.After(d):
	}
}
