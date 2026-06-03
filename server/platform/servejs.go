package platform

import "net/http"

// ServeJS reads `path` from the embedded assets and writes it as
// application/javascript. On read failure it returns a 404 with the
// supplied missing-file message (intended to point the developer at the
// build step that produces the asset). Shared by the Lyn Rummy and Chat
// JS routes.
func ServeJS(w http.ResponseWriter, path string, missingMsg string) {
	data, err := ReadAsset(path)
	if err != nil {
		http.Error(w, missingMsg, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}
