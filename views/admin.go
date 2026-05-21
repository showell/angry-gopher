// Admin screen: a filesystem view of how much session data each
// player has generated, plus a guarded action to delete a player's
// data. No DB — it walks {GameDataRoot}/{user}/ directly, which is
// also the on-disk partition layout (one top-level dir per user).
package views

import (
	"fmt"
	"html"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"

	"angry-gopher/auth"
)

// UserStats is a per-player rollup of on-disk session data.
type UserStats struct {
	Name           string
	GameSessions   int
	PuzzleSessions int
	TotalActions   int
	DiskBytes      int64
}

// HandleAdmin dispatches the admin surface: the read-only overview at
// /admin and the destructive delete-a-player flow at /admin/delete.
func HandleAdmin(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/admin/delete" {
		handleAdminDelete(w, r)
		return
	}
	renderAdminOverview(w, r)
}

// renderAdminOverview renders the per-player stats table.
func renderAdminOverview(w http.ResponseWriter, r *http.Request) {
	users := listUsers()

	var grand UserStats
	grand.Name = "All players"
	rows := make([]UserStats, 0, len(users))
	for _, u := range users {
		st := gatherUserStats(u)
		rows = append(rows, st)
		grand.GameSessions += st.GameSessions
		grand.PuzzleSessions += st.PuzzleSessions
		grand.TotalActions += st.TotalActions
		grand.DiskBytes += st.DiskBytes
	}

	flash := ""
	if deleted := auth.SanitizeUser(r.URL.Query().Get("deleted")); deleted != "" {
		flash = fmt.Sprintf(`<p class="flash">Deleted all data for <strong>%s</strong>.</p>`,
			html.EscapeString(deleted))
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 880px; }
h1 { color: #000080; }
nav { font-size: 13px; margin-bottom: 16px; }
nav a { color: #000080; }
table { border-collapse: collapse; width: 100%%; margin-top: 12px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
.n { text-align: right; font-variant-numeric: tabular-nums; }
.total td { font-weight: bold; border-top: 2px solid #000080; background: #f4f4ec; }
.muted { color: #888; }
.flash { background: #c6f6c6; color: #1a7a3a; padding: 8px 12px; border-radius: 4px; }
a.del { color: #b00020; text-decoration: none; }
a.del:hover { text-decoration: underline; }
</style>
</head><body>
<nav><a href="/">← Home</a></nav>
<h1>🐹 Angry Gopher Admin</h1>
%s<p class="muted">Sessions generated per player. Read straight from %s.</p>
<table>
<tr><th>Player</th><th class="n">Games</th><th class="n">Puzzles</th><th class="n">Actions</th><th class="n">Disk</th><th></th></tr>`,
		flash, html.EscapeString(GameDataRoot))

	if len(rows) == 0 {
		fmt.Fprint(w, `<tr><td colspan="6" class="muted">No players yet.</td></tr>`)
	}
	for _, st := range rows {
		del := fmt.Sprintf(`<a class="del" href="/admin/delete?user=%s">Delete sessions</a>`,
			url.QueryEscape(st.Name))
		writeStatsRow(w, st, "", del)
	}
	if len(rows) > 1 {
		writeStatsRow(w, grand, "total", "")
	}
	fmt.Fprint(w, `</table></body></html>`)
}

func writeStatsRow(w http.ResponseWriter, st UserStats, cls, actionsCell string) {
	rowClass := ""
	if cls != "" {
		rowClass = ` class="` + cls + `"`
	}
	fmt.Fprintf(w,
		`<tr%s><td>%s</td><td class="n">%d</td><td class="n">%d</td><td class="n">%d</td><td class="n">%s</td><td>%s</td></tr>`,
		rowClass, html.EscapeString(st.Name), st.GameSessions, st.PuzzleSessions,
		st.TotalActions, humanBytes(st.DiskBytes), actionsCell)
}

// handleAdminDelete confirms (GET) and performs (POST) deletion of one
// player's on-disk data. The user param goes through the same sanitizer
// as login, so it can never escape GameDataRoot.
func handleAdminDelete(w http.ResponseWriter, r *http.Request) {
	user := auth.SanitizeUser(r.FormValue("user"))
	if user == "" {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	if _, err := os.Stat(filepath.Join(GameDataRoot, user)); err != nil {
		// Already gone (or never existed) — nothing to confirm or delete.
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	if r.Method == http.MethodPost {
		if err := DeleteUserData(user); err != nil {
			http.Error(w, "delete: "+err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/admin?deleted="+url.QueryEscape(user), http.StatusSeeOther)
		return
	}
	renderDeleteConfirm(w, user)
}

// renderDeleteConfirm is the "are you sure" page: it spells out exactly
// what will be removed before the POST that does it.
func renderDeleteConfirm(w http.ResponseWriter, user string) {
	st := gatherUserStats(user)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 560px; }
h1 { color: #000080; }
nav { font-size: 13px; margin-bottom: 16px; }
nav a, .cancel { color: #000080; }
.warn { color: #b00020; }
.box { background: #f4f4ec; border: 1px solid #ccc; border-radius: 6px; padding: 4px 20px 20px; }
button.danger { background: #b00020; color: white; border: none; padding: 10px 18px;
                font-size: 15px; border-radius: 4px; cursor: pointer; }
button.danger:hover { background: #8a0019; }
.cancel { margin-left: 16px; }
</style>
</head><body>
<nav><a href="/admin">← Admin</a></nav>
<h1>Delete sessions for &ldquo;%s&rdquo;?</h1>
<div class="box">
<p>This permanently removes <strong>all</strong> on-disk data for this player:</p>
<p><strong>%d</strong> games · <strong>%d</strong> puzzles · %d actions · %s on disk</p>
<p class="warn">This cannot be undone. (They can log in again later; a fresh, empty history is created.)</p>
<form method="post" action="/admin/delete">
  <input type="hidden" name="user" value="%s">
  <button type="submit" class="danger">Yes, delete</button>
  <a class="cancel" href="/admin">Cancel</a>
</form>
</div>
</body></html>`,
		html.EscapeString(user), st.GameSessions, st.PuzzleSessions, st.TotalActions,
		humanBytes(st.DiskBytes), html.EscapeString(user))
}

// listUsers returns the player directories directly under
// GameDataRoot, sorted.
func listUsers() []string {
	entries, err := os.ReadDir(GameDataRoot)
	if err != nil {
		return nil
	}
	users := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			users = append(users, e.Name())
		}
	}
	sort.Strings(users)
	return users
}

// gatherUserStats walks one player's subtree. Independent of the
// currentUser write-path machinery so it can report on every player.
func gatherUserStats(user string) UserStats {
	uRoot := filepath.Join(GameDataRoot, user)
	gamesDir := filepath.Join(uRoot, "lynrummy-elm", "sessions")
	puzzlesDir := filepath.Join(uRoot, "puzzle", "sessions")

	st := UserStats{
		Name:           user,
		GameSessions:   countSubdirs(gamesDir),
		PuzzleSessions: countSubdirs(puzzlesDir),
		DiskBytes:      dirBytes(uRoot),
	}
	if entries, err := os.ReadDir(gamesDir); err == nil {
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			n, _ := CountTextLines(filepath.Join(gamesDir, e.Name(), "actions.dsl"))
			st.TotalActions += n
		}
	}
	return st
}

func countSubdirs(dir string) int {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range entries {
		if e.IsDir() {
			n++
		}
	}
	return n
}

func dirBytes(root string) int64 {
	var total int64
	filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			if info, ierr := d.Info(); ierr == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
}
