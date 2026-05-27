// migrate_image_dims rewrites existing chat image references from the
// markdown-image form `![alt](/chat/uploads/<key>/<file>)` to the new
// HTML form `<img src="..." alt="..." width="W" height="H">`, decoding
// the dimensions from the actual file on disk.
//
// Why: messages without width/height attrs reflow when the image bytes
// arrive, which yanks the "scroll to bottom" target out from under us
// on initial load. The new upload path emits width/height up front;
// this tool retrofits the same to existing messages so the whole feed
// renders without layout shift.
//
// One-shot, idempotent: a message already in HTML form is left alone.
// Safe to re-run.
//
// Usage:
//
//	go run ./tools/migrate_image_dims/ <chat-data-root>
//
// The tool walks <chat-data-root>/<pair-key>/messages.md and rewrites
// each in place. It does NOT touch the hash on the MSG_ line — the
// stored hash is the canonical id, not a checksum that gets re-verified.
// Run while the server is stopped (or with the conversation otherwise
// quiet); we don't take the chat mutex and a concurrent append could
// race the rewrite.
package main

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// markdownImageRe matches the existing form. We only rewrite refs whose
// URL starts with /chat/uploads/<key>/<file> — outside URLs (a future
// remote image) are left as plain markdown.
var markdownImageRe = regexp.MustCompile(`!\[([^\]]*)\]\((/chat/uploads/[^)]+)\)`)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: migrate_image_dims <chat-data-root>")
		os.Exit(1)
	}
	root := os.Args[1]
	st, err := os.Stat(root)
	if err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "not a directory: %s\n", root)
		os.Exit(1)
	}

	convDirs, err := os.ReadDir(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read root: %v\n", err)
		os.Exit(1)
	}

	totalConvs, totalRewrites, totalSkipped, totalErrors := 0, 0, 0, 0
	for _, d := range convDirs {
		if !d.IsDir() {
			continue
		}
		// Skip the per-user docs subtree (users/<uid>/docs/*.md) — those are
		// authoring artifacts, not conversation transcripts, and we shouldn't
		// rewrite them. Only the <a>_<b> pair-key dirs hold messages.md.
		if d.Name() == "users" {
			continue
		}
		path := filepath.Join(root, d.Name(), "messages.md")
		if _, err := os.Stat(path); err != nil {
			continue
		}
		totalConvs++
		rewrites, skipped, errs := migrateFile(path, root, d.Name())
		totalRewrites += rewrites
		totalSkipped += skipped
		totalErrors += errs
		if rewrites > 0 || errs > 0 {
			fmt.Printf("  %s: rewrote %d, skipped %d, errors %d\n",
				path, rewrites, skipped, errs)
		}
	}
	fmt.Printf("done: %d conversation(s), %d rewrite(s), %d already-HTML, %d error(s)\n",
		totalConvs, totalRewrites, totalSkipped, totalErrors)
	if totalErrors > 0 {
		os.Exit(2)
	}
}

// migrateFile rewrites one messages.md in place. Returns (rewrites,
// alreadyHTMLcount, errors). "Errors" are per-image-ref decode failures —
// they're logged but don't abort: we still write the file with the
// other rewrites applied. Decode failures leave the original markdown
// untouched, so a re-run will retry.
func migrateFile(path, root, convDir string) (int, int, int) {
	src, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "    read %s: %v\n", path, err)
		return 0, 0, 1
	}
	rewrites, errs := 0, 0
	out := markdownImageRe.ReplaceAllFunc(src, func(match []byte) []byte {
		m := markdownImageRe.FindSubmatch(match)
		alt := string(m[1])
		ref := string(m[2]) // /chat/uploads/<key>/<file>
		filePath, ok := resolveUploadPath(root, ref)
		if !ok {
			errs++
			fmt.Fprintf(os.Stderr, "    %s: unresolvable upload ref %q (left as markdown)\n", path, ref)
			return match
		}
		w, h, derr := decodeImageDims(filePath)
		if derr != nil {
			errs++
			fmt.Fprintf(os.Stderr, "    %s: decode %s: %v (left as markdown)\n", path, filePath, derr)
			return match
		}
		rewrites++
		return []byte(buildHTMLImg(ref, alt, w, h))
	})
	if rewrites == 0 && errs == 0 {
		// Nothing to do; don't even rewrite the file (preserves mtime).
		alreadyHTML := bytes.Count(src, []byte(`<img src="/chat/uploads/`))
		return 0, alreadyHTML, 0
	}
	// Atomic-ish write: write to temp + rename so a crash doesn't leave a
	// half-rewritten file. Same dir so rename is atomic on the same fs.
	tmp := path + ".migrate-tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "    write %s: %v\n", tmp, err)
		return rewrites, 0, errs + 1
	}
	if err := os.Rename(tmp, path); err != nil {
		fmt.Fprintf(os.Stderr, "    rename %s: %v\n", tmp, err)
		_ = os.Remove(tmp)
		return rewrites, 0, errs + 1
	}
	return rewrites, 0, errs
}

// resolveUploadPath maps "/chat/uploads/<key>/<file>" to the on-disk
// "<root>/<key>/uploads/<file>". The key in the URL is path-escaped;
// the on-disk dir name is the unescaped form (matches chatPairKey).
func resolveUploadPath(root, ref string) (string, bool) {
	const prefix = "/chat/uploads/"
	if !strings.HasPrefix(ref, prefix) {
		return "", false
	}
	rest := strings.TrimPrefix(ref, prefix)
	slash := strings.IndexByte(rest, '/')
	if slash < 0 {
		return "", false
	}
	keyEscaped, name := rest[:slash], rest[slash+1:]
	key, err := url.PathUnescape(keyEscaped)
	if err != nil {
		return "", false
	}
	return filepath.Join(root, key, "uploads", name), true
}

func decodeImageDims(path string) (int, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		return 0, 0, err
	}
	return cfg.Width, cfg.Height, nil
}

// buildHTMLImg matches what the upload handler now emits, so the
// migrated form is identical to a freshly-uploaded image. Alt is
// minimally escaped — the prior markdown alt rejected `[]` and newlines
// already, so the only new characters to worry about are " and <>.
func buildHTMLImg(src, alt string, w, h int) string {
	alt = strings.NewReplacer(`"`, "&quot;", `<`, "&lt;", `>`, "&gt;").Replace(alt)
	return fmt.Sprintf(`<img src="%s" alt="%s" width="%d" height="%d">`, src, alt, w, h)
}
