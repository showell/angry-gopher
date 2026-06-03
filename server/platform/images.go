package platform

import (
	"net/http"
	"strings"
)

// imageAllowlist names every brand/avatar image the binary will serve from
// /images/<file>. Explicit allowlist (not a directory walk) so adding a
// shared image is one line here AND a //go:embed line in embed.go — the
// edit you make on the Go side has to match the edit on the embed side, no
// silent path-traversal surface.
var imageAllowlist = map[string]string{
	"cat_professor.webp": "images/cat_professor.webp",
}

// HandleImage serves /images/{file} from the embedded assets. Content-Type
// is derived from the extension; only the small set we host is wired.
func HandleImage(w http.ResponseWriter, r *http.Request) {
	file := r.PathValue("file")
	path, ok := imageAllowlist[file]
	if !ok {
		http.NotFound(w, r)
		return
	}
	data, err := ReadAsset(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch {
	case strings.HasSuffix(file, ".webp"):
		w.Header().Set("Content-Type", "image/webp")
	case strings.HasSuffix(file, ".png"):
		w.Header().Set("Content-Type", "image/png")
	case strings.HasSuffix(file, ".svg"):
		w.Header().Set("Content-Type", "image/svg+xml")
	}
	w.Write(data)
}
