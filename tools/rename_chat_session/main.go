// rename_chat_session renames one session of a conversation — which, since a
// topic is just a session with a custom name, is also how you'd rename a
// topic. It rewrites everything that embeds the old session id so the rename
// is invisible to "being in a session":
//
//   - the MSG_<sid>_<n> ids on each block, and every in-body reference to
//     them (quote/refer/"See MSG_…"), ACROSS ALL session files in the conv
//     (cross-session refs point at the renamed one too);
//   - image URLs /chat/c/<conv>/<old>/uploads/… → …/<new>/uploads/…;
//   - the session file <old>.md and its uploads sidecar <old>.uploads/;
//   - the per-user last-session pointers (users/<uid>/last-sessions/<conv>).
//
// The per-message `date:` headers and any prose mention of the date are left
// alone — they stay truthful; only the session's *name* changes. An optional
// description is written to <new>.meta.json (the topic's human-readable
// blurb; the slug stays the source of truth).
//
// One-way (a rename), but safe to mis-run: it refuses unless <old>.md exists
// and <new> is a fresh, valid session slug.
//
//   go run ./tools/rename_chat_session/ <chat-data-root> <conv> <old-sid> <new-sid> [description]
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// A session id (date slug or topic slug) is kebab-case with no underscores —
// the underscore is reserved as the MSG_<sid>_<n> separator.
var sidRe = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)

func main() {
	args := os.Args[1:]
	if len(args) < 4 || len(args) > 5 {
		fmt.Fprintln(os.Stderr, "usage: rename_chat_session <chat-data-root> <conv> <old-sid> <new-sid> [description]")
		os.Exit(1)
	}
	root, conv, oldSid, newSid := args[0], args[1], args[2], args[3]
	desc := ""
	if len(args) == 5 {
		desc = args[4]
	}

	sessionsDir := filepath.Join(root, conv, "sessions")
	oldMd := filepath.Join(sessionsDir, oldSid+".md")
	newMd := filepath.Join(sessionsDir, newSid+".md")

	if !sidRe.MatchString(newSid) {
		fail("new-sid %q is not a valid session slug (lowercase a-z0-9 and hyphens, no underscores)", newSid)
	}
	if st, err := os.Stat(oldMd); err != nil || st.IsDir() {
		fail("source session %s does not exist", oldMd)
	}
	if _, err := os.Stat(newMd); err == nil {
		fail("target session %s already exists — refusing to clobber", newMd)
	}

	// 1) Rewrite embedded references across EVERY session file in the conv.
	idRe := regexp.MustCompile(`MSG_` + regexp.QuoteMeta(oldSid) + `_(\d+)`)
	urlOld := "/chat/c/" + conv + "/" + oldSid + "/"
	urlNew := "/chat/c/" + conv + "/" + newSid + "/"
	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		fail("read %s: %v", sessionsDir, err)
	}
	totalIDs, totalURLs, filesTouched := 0, 0, 0
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".md" {
			continue
		}
		p := filepath.Join(sessionsDir, e.Name())
		src, err := os.ReadFile(p)
		if err != nil {
			fail("read %s: %v", p, err)
		}
		ids := len(idRe.FindAll(src, -1))
		urls := strings.Count(string(src), urlOld)
		if ids == 0 && urls == 0 {
			continue
		}
		out := idRe.ReplaceAll(src, []byte("MSG_"+newSid+"_$1"))
		out = []byte(strings.ReplaceAll(string(out), urlOld, urlNew))
		if err := os.WriteFile(p, out, 0o644); err != nil {
			fail("write %s: %v", p, err)
		}
		filesTouched++
		totalIDs += ids
		totalURLs += urls
		fmt.Printf("  %s: %d MSG_ id/ref(s), %d image URL(s)\n", e.Name(), ids, urls)
	}

	// 2) Rename the session file (after rewriting, so the cross-file scan
	//    above saw the original name) and its uploads sidecar.
	if err := os.Rename(oldMd, newMd); err != nil {
		fail("rename %s -> %s: %v", oldMd, newMd, err)
	}
	fmt.Printf("  renamed %s.md -> %s.md\n", oldSid, newSid)
	oldUp := filepath.Join(sessionsDir, oldSid+".uploads")
	if _, err := os.Stat(oldUp); err == nil {
		newUp := filepath.Join(sessionsDir, newSid+".uploads")
		if err := os.Rename(oldUp, newUp); err != nil {
			fail("rename uploads %s -> %s: %v", oldUp, newUp, err)
		}
		fmt.Printf("  renamed %s.uploads/ -> %s.uploads/\n", oldSid, newSid)
	}

	// 3) Repoint any per-user last-session pointer that named the old sid.
	usersDir := filepath.Join(root, "users")
	if uids, err := os.ReadDir(usersDir); err == nil {
		for _, u := range uids {
			if !u.IsDir() {
				continue
			}
			ptr := filepath.Join(usersDir, u.Name(), "last-sessions", conv)
			b, err := os.ReadFile(ptr)
			if err != nil {
				continue
			}
			if strings.TrimSpace(string(b)) == oldSid {
				if err := os.WriteFile(ptr, []byte(newSid+"\n"), 0o644); err != nil {
					fail("repoint %s: %v", ptr, err)
				}
				fmt.Printf("  repointed users/%s/last-sessions/%s -> %s\n", u.Name(), conv, newSid)
			}
		}
	}

	// 4) Write the topic description sidecar (the slug stays canonical).
	if desc != "" {
		metaPath := filepath.Join(sessionsDir, newSid+".meta.json")
		blob, _ := json.MarshalIndent(map[string]string{"description": desc}, "", "  ")
		if err := os.WriteFile(metaPath, append(blob, '\n'), 0o644); err != nil {
			fail("write %s: %v", metaPath, err)
		}
		fmt.Printf("  wrote %s.meta.json\n", newSid)
	}

	fmt.Printf("done: %s -> %s (%d files, %d ids, %d urls)\n", oldSid, newSid, filesTouched, totalIDs, totalURLs)
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "rename_chat_session: "+format+"\n", a...)
	os.Exit(1)
}
