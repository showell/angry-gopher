// Package respond provides JSON response helpers and shared HTTP
// utilities for API handlers.
package respond

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

func WriteJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func Error(w http.ResponseWriter, msg string) {
	WriteJSON(w, map[string]interface{}{
		"result": "error",
		"msg":    msg,
	})
}

// PathSegmentInt extracts an integer from a URL path segment by index.
// For example, PathSegmentInt("/api/v1/messages/42/reactions", 4) returns 42.
// Returns 0 if the index is out of range or the segment isn't a valid integer.
func PathSegmentInt(path string, index int) int {
	parts := strings.Split(path, "/")
	if index >= len(parts) {
		return 0
	}
	n, _ := strconv.Atoi(parts[index])
	return n
}

// ParseFormBody ensures the request body is parsed as form data,
// even for methods like DELETE where Go doesn't auto-parse it.
func ParseFormBody(r *http.Request) {
	origMethod := r.Method
	r.Method = "POST"
	r.ParseForm()
	r.Method = origMethod
}

func Success(w http.ResponseWriter, extra map[string]interface{}) {
	result := map[string]interface{}{
		"result": "success",
		"msg":    "",
	}
	for k, v := range extra {
		result[k] = v
	}
	WriteJSON(w, result)
}
