// Transcript download — the "d" hotkey's server side. Where /raw serves
// the single .md text, this bundles a whole topic (the transcript plus
// every image it references) into one .tar.gz the browser saves. Same
// participant auth + same on-disk source of truth as /raw; the thin DM
// and channel handlers live next to their /raw siblings (chat_stream.go,
// channel_handlers.go) and both funnel here.
package chat

import (
	"archive/tar"
	"compress/gzip"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// serveTranscriptBundle streams a topic as a gzipped tarball laid out as
//
//	<sid>/<sid>.md          — the literal transcript (same bytes as /raw)
//	<sid>/uploads/<file>    — every image in the topic's .uploads dir
//
// The .lastauthor companion is deliberately omitted: it's internal
// bookkeeping (a bare uid), not part of the human transcript. Headers go
// out before the first archive byte, and the write deadline is cleared so
// a large bundle on a slow connection can't be truncated mid-stream (the
// same hazard the SSE path guards against).
func serveTranscriptBundle(w http.ResponseWriter, r *http.Request, c Conv, sid string) {
	md, err := c.RawSession(sid)
	if err != nil {
		http.NotFound(w, r) // missing/unreadable topic — don't distinguish
		return
	}

	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+sid+`.tar.gz"`)
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	gz := gzip.NewWriter(w)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	// The transcript. Use the file's mtime when we can; it's cosmetic, so
	// a stat failure just falls back to now.
	mdMod := time.Now()
	if info, statErr := os.Stat(c.SessionPath(sid)); statErr == nil {
		mdMod = info.ModTime()
	}
	if addTarBytes(tw, sid+"/"+sid+".md", md, mdMod) != nil {
		return // client gone — nothing useful left to do
	}

	// The images. Append-only once written, so reading them unlocked is
	// safe. A missing dir (no images yet) just yields an empty range.
	uploadsDir := c.UploadsDir(sid)
	entries, _ := os.ReadDir(uploadsDir)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, readErr := os.ReadFile(filepath.Join(uploadsDir, e.Name()))
		if readErr != nil {
			continue // skip an unreadable upload rather than abort the bundle
		}
		mod := time.Now()
		if info, infoErr := e.Info(); infoErr == nil {
			mod = info.ModTime()
		}
		if addTarBytes(tw, sid+"/uploads/"+e.Name(), data, mod) != nil {
			return
		}
	}
}

// addTarBytes writes one regular file into the tar stream.
func addTarBytes(tw *tar.Writer, name string, data []byte, mod time.Time) error {
	hdr := &tar.Header{
		Name:     name,
		Mode:     0o644,
		Size:     int64(len(data)),
		ModTime:  mod,
		Typeflag: tar.TypeReg,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	_, err := tw.Write(data)
	return err
}
