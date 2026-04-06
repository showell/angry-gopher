// Angry Gopher — a reverse proxy that sits between Angry Cat and Zulip.
//
// Listens on port 9000 and forwards all requests to the upstream Zulip
// server. Angry Cat connects here instead of directly to Zulip.
//
// Over time, we'll replace proxied endpoints with our own implementations
// backed by SQLite.

package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
)

const (
	listenAddr  = ":9000"
	upstreamURL = "https://macandcheese.zulipchat.com"
)

func main() {
	http.HandleFunc("/", proxyHandler)

	fmt.Printf("Angry Gopher listening on %s\n", listenAddr)
	fmt.Printf("Proxying to %s\n", upstreamURL)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	// Build the upstream URL from the incoming request.
	targetURL := upstreamURL + r.URL.Path
	if r.URL.RawQuery != "" {
		targetURL += "?" + r.URL.RawQuery
	}

	// Log the request for visibility.
	log.Printf("%s %s", r.Method, r.URL.Path)

	// Create the upstream request.
	upstreamReq, err := http.NewRequest(r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, "Failed to create upstream request", http.StatusInternalServerError)
		log.Printf("  ERROR creating request: %v", err)
		return
	}

	// Forward all headers (including Authorization).
	for key, values := range r.Header {
		for _, value := range values {
			upstreamReq.Header.Add(key, value)
		}
	}

	// Send the request to Zulip.
	client := &http.Client{}
	resp, err := client.Do(upstreamReq)
	if err != nil {
		http.Error(w, "Failed to reach upstream", http.StatusBadGateway)
		log.Printf("  ERROR reaching upstream: %v", err)
		return
	}
	defer resp.Body.Close()

	// Copy response headers back to the client.
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}

	// Add CORS headers so Angry Cat (running on a different port) can
	// talk to us.
	origin := r.Header.Get("Origin")
	if origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
	}

	// Handle CORS preflight.
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	w.WriteHeader(resp.StatusCode)

	// Stream the response body back to the client. This is important
	// for long-polling endpoints like /api/v1/events.
	if strings.Contains(r.URL.Path, "/events") {
		// Flush immediately for event polling.
		flusher, ok := w.(http.Flusher)
		buf := make([]byte, 4096)
		for {
			n, readErr := resp.Body.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
				if ok {
					flusher.Flush()
				}
			}
			if readErr != nil {
				break
			}
		}
	} else {
		io.Copy(w, resp.Body)
	}
}
