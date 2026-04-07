// Package respond provides JSON response helpers for API handlers.
package respond

import (
	"encoding/json"
	"net/http"
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
