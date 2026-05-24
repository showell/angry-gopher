// Per-request body-size limits for the session write paths. Caddy
// caps body size in front too, but these are the in-process backstop.
package lynrummy

import (
	"errors"
	"io"
	"net/http"
)

const (
	// maxNewSessionBytes caps a new-session game-state DSL. A full
	// two-deck board is a few KB; this leaves generous headroom.
	maxNewSessionBytes = 256 * 1024
	// maxAppendBytes caps a single action/annotation line. Real lines
	// are well under 4 KB.
	maxAppendBytes = 64 * 1024
)

// readLimitedBody reads the request body capped at maxBytes. On
// success returns (body, true). If the cap is exceeded it writes a 413;
// any other read error writes a 400; either way it returns (nil, false).
// Callers should just `return` when ok is false.
func readLimitedBody(w http.ResponseWriter, r *http.Request, maxBytes int64) ([]byte, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	body, err := io.ReadAll(r.Body)
	if err == nil {
		return body, true
	}

	var maxErr *http.MaxBytesError
	if errors.As(err, &maxErr) {
		http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
		return nil, false
	}

	http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
	return nil, false
}
