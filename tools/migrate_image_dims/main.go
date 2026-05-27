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
// Legacy-key healing: an older identity migration (numeric user ids,
// 2026-05-23) renamed the on-disk conv dirs (e.g. apoorva_Steve → 1_2)
// but did not rewrite URLs in prior messages, so older image refs are
// now 404-ing in the live UI. When the URL's stated key dir is missing
// but the bare filename exists under another conv dir on disk, we
// rewrite the URL to the canonical key in the same pass — the upload
// filename is a 32-hex random token, so a cross-dir match is unique.
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

	// Index every upload file across all conv dirs once, so the legacy-key
	// fallback (file lookup by bare name) is O(1) per ref instead of
	// O(dirs). Names are 32-hex random tokens — collisions across dirs
	// would be a real cryptographic event, not a bug to handle.
	uploadsByName := indexUploads(root)

	totalConvs, totalRewrites, totalRehealed, totalSkipped, totalErrors := 0, 0, 0, 0, 0
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
		// The conv-dir name IS the canonical key — that's where we rewrite
		// legacy URLs to point (the file already lives under it on disk).
		canonicalKey := d.Name()
		rewrites, rehealed, skipped, errs := migrateFile(path, root, canonicalKey, uploadsByName)
		totalRewrites += rewrites
		totalRehealed += rehealed
		totalSkipped += skipped
		totalErrors += errs
		if rewrites > 0 || rehealed > 0 || errs > 0 {
			fmt.Printf("  %s: rewrote %d (incl. %d URL-key-rehealed), skipped %d, errors %d\n",
				path, rewrites, rehealed, skipped, errs)
		}
	}
	fmt.Printf("done: %d conversation(s), %d rewrite(s) (%d URL-key-rehealed), %d already-HTML, %d error(s)\n",
		totalConvs, totalRewrites, totalRehealed, totalSkipped, totalErrors)
	if totalErrors > 0 {
		os.Exit(2)
	}
}

// indexUploads scans every <root>/<conv>/uploads/<file> and returns a
// map from bare filename to the conv key it lives under. Used to heal
// legacy URLs whose stated key dir no longer exists on disk.
func indexUploads(root string) map[string]string {
	out := map[string]string{}
	dirs, err := os.ReadDir(root)
	if err != nil {
		return out
	}
	for _, d := range dirs {
		if !d.IsDir() || d.Name() == "users" {
			continue
		}
		ud := filepath.Join(root, d.Name(), "uploads")
		files, err := os.ReadDir(ud)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() {
				continue
			}
			out[f.Name()] = d.Name()
		}
	}
	return out
}

// migrateFile rewrites one messages.md in place. Returns (rewrites,
// rehealed, alreadyHTMLcount, errors). "Rehealed" is the subset of
// rewrites whose URL key was changed because the original key dir was
// missing (legacy form). "Errors" are per-image-ref decode failures —
// they're logged but don't abort: we still write the file with the
// other rewrites applied. Decode failures leave the original markdown
// untouched, so a re-run will retry.
func migrateFile(path, root, canonicalKey string, uploadsByName map[string]string) (int, int, int, int) {
	src, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "    read %s: %v\n", path, err)
		return 0, 0, 0, 1
	}
	rewrites, rehealed, errs := 0, 0, 0
	out := markdownImageRe.ReplaceAllFunc(src, func(match []byte) []byte {
		m := markdownImageRe.FindSubmatch(match)
		alt := string(m[1])
		ref := string(m[2]) // /chat/uploads/<key>/<file>
		urlKey, fileName, ok := splitUploadRef(ref)
		if !ok {
			errs++
			fmt.Fprintf(os.Stderr, "    %s: unrecognized upload ref %q (left as markdown)\n", path, ref)
			return match
		}
		// Try the URL's stated key first. If the file isn't there but it
		// IS somewhere on disk, heal the URL to the canonical key for THIS
		// conv (that's where messages.md lives, so the file should live
		// under the same conv key).
		diskPath := filepath.Join(root, urlKey, "uploads", fileName)
		healedRef := ""
		if _, err := os.Stat(diskPath); err != nil {
			foundKey, ok := uploadsByName[fileName]
			if !ok {
				errs++
				fmt.Fprintf(os.Stderr, "    %s: file %q not found anywhere (left as markdown)\n", path, fileName)
				return match
			}
			diskPath = filepath.Join(root, foundKey, "uploads", fileName)
			healedRef = "/chat/uploads/" + canonicalKey + "/" + fileName
		}
		w, h, derr := decodeImageDims(diskPath)
		if derr != nil {
			errs++
			fmt.Fprintf(os.Stderr, "    %s: decode %s: %v (left as markdown)\n", path, diskPath, derr)
			return match
		}
		rewrites++
		emitRef := ref
		if healedRef != "" {
			emitRef = healedRef
			rehealed++
		}
		return []byte(buildHTMLImg(emitRef, alt, w, h))
	})
	if rewrites == 0 && errs == 0 {
		// Nothing to do; don't even rewrite the file (preserves mtime).
		alreadyHTML := bytes.Count(src, []byte(`<img src="/chat/uploads/`))
		return 0, 0, alreadyHTML, 0
	}
	// Atomic-ish write: write to temp + rename so a crash doesn't leave a
	// half-rewritten file. Same dir so rename is atomic on the same fs.
	tmp := path + ".migrate-tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "    write %s: %v\n", tmp, err)
		return rewrites, rehealed, 0, errs + 1
	}
	if err := os.Rename(tmp, path); err != nil {
		fmt.Fprintf(os.Stderr, "    rename %s: %v\n", tmp, err)
		_ = os.Remove(tmp)
		return rewrites, rehealed, 0, errs + 1
	}
	return rewrites, rehealed, 0, errs
}

// splitUploadRef parses "/chat/uploads/<key>/<file>" into (key, file).
// The key in the URL is path-escaped; we return the unescaped form so it
// matches the on-disk dir name (chatPairKey output).
func splitUploadRef(ref string) (string, string, bool) {
	const prefix = "/chat/uploads/"
	if !strings.HasPrefix(ref, prefix) {
		return "", "", false
	}
	rest := strings.TrimPrefix(ref, prefix)
	slash := strings.IndexByte(rest, '/')
	if slash < 0 {
		return "", "", false
	}
	keyEscaped, name := rest[:slash], rest[slash+1:]
	key, err := url.PathUnescape(keyEscaped)
	if err != nil {
		return "", "", false
	}
	return key, name, true
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
