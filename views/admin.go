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
	"strings"
	"time"
)

// UserStats is a per-player rollup of on-disk session data.
type UserStats struct {
	ID             string
	Name           string
	GameSessions   int
	PuzzleSessions int
	TotalActions   int
	DiskBytes      int64
}

// HandleAdmin dispatches the admin surface. Admin powers are tied to the
// user (the admin flag); non-admins get a 404 (don't reveal it exists).
func HandleAdmin(w http.ResponseWriter, r *http.Request) {
	if !CurrentUser(r).Admin {
		http.NotFound(w, r)
		return
	}
	if r.URL.Path == "/admin/delete" {
		handleAdminDelete(w, r)
		return
	}
	renderAdminOverview(w, r)
}

// renderAdminOverview renders the per-player stats table.
func renderAdminOverview(w http.ResponseWriter, r *http.Request) {
	ids := ListUserIDs()

	var grand UserStats
	grand.Name = "All players"
	rows := make([]UserStats, 0, len(ids))
	for _, id := range ids {
		st := gatherUserStats(id)
		rows = append(rows, st)
		grand.GameSessions += st.GameSessions
		grand.PuzzleSessions += st.PuzzleSessions
		grand.TotalActions += st.TotalActions
		grand.DiskBytes += st.DiskBytes
	}

	flash := ""
	if deleted := strings.TrimSpace(r.URL.Query().Get("deleted")); deleted != "" {
		flash = fmt.Sprintf(`<p class="flash">Deleted game data for <strong>%s</strong>.</p>`,
			html.EscapeString(GetUserName(deleted)))
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 880px; }
h1 { color: #000080; }
h2 { color: #000080; font-size: 18px; margin-top: 32px; }
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
%s`, flash)

	renderMembersTable(w)

	fmt.Fprintf(w, `<h2>Sessions per player</h2>
<p class="muted">Read straight from %s.</p>
<table>
<tr><th>Player</th><th class="n">Games</th><th class="n">Puzzles</th><th class="n">Actions</th><th class="n">Disk</th><th></th></tr>`,
		html.EscapeString(GameDataRoot))

	if len(rows) == 0 {
		fmt.Fprint(w, `<tr><td colspan="6" class="muted">No players yet.</td></tr>`)
	}
	for _, st := range rows {
		del := fmt.Sprintf(`<a class="del" href="/admin/delete?user=%s">Delete sessions</a>`,
			url.QueryEscape(st.ID))
		writeStatsRow(w, st, "", del)
	}
	if len(rows) > 1 {
		writeStatsRow(w, grand, "total", "")
	}
	fmt.Fprint(w, `</table></body></html>`)
}

// renderMembersTable lists the official users (those with a password) and
// how long since each was last active, most-recent first. Members who have
// never registered any activity sort to the bottom.
func renderMembersTable(w http.ResponseWriter) {
	members := ListMembers()

	type memberRow struct {
		user   User
		active time.Time
		ever   bool
	}
	rows := make([]memberRow, 0, len(members))
	for _, m := range members {
		t, ok := UserLastActive(m.ID)
		rows = append(rows, memberRow{user: m, active: t, ever: ok})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].ever != rows[j].ever {
			return rows[i].ever // active-ever sorts above never-active
		}
		return rows[i].active.After(rows[j].active)
	})

	fmt.Fprint(w, `<h2>Official users</h2>
<p class="muted">Members (password holders) and time since last activity.</p>
<table>
<tr><th>Name</th><th>Last active</th></tr>`)
	if len(rows) == 0 {
		fmt.Fprint(w, `<tr><td colspan="2" class="muted">No members yet.</td></tr>`)
	}
	for _, row := range rows {
		name := html.EscapeString(row.user.Name)
		if row.user.Admin {
			name += ` <span class="muted">(admin)</span>`
		}
		since := "never"
		if row.ever {
			since = humanizeSince(row.active)
		}
		fmt.Fprintf(w, `<tr><td>%s</td><td>%s</td></tr>`, name, since)
	}
	fmt.Fprint(w, `</table>`)
}

// humanizeSince renders elapsed time since t as a coarse relative string.
func humanizeSince(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
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
// player's on-disk game data, by user id.
func handleAdminDelete(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.FormValue("user")) // user id
	if id == "" || !UserExists(id) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	if r.Method == http.MethodPost {
		if err := DeleteUserData(id); err != nil {
			http.Error(w, "delete: "+err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/admin?deleted="+url.QueryEscape(id), http.StatusSeeOther)
		return
	}
	renderDeleteConfirm(w, id)
}

// renderDeleteConfirm is the "are you sure" page: it spells out exactly
// what will be removed before the POST that does it.
func renderDeleteConfirm(w http.ResponseWriter, id string) {
	st := gatherUserStats(id)
	name := GetUserName(id)
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
		html.EscapeString(name), st.GameSessions, st.PuzzleSessions, st.TotalActions,
		humanBytes(st.DiskBytes), html.EscapeString(id))
}

// gatherUserStats walks one player's subtree. Independent of the
// currentUser write-path machinery so it can report on every player.
func gatherUserStats(user string) UserStats {
	uRoot := filepath.Join(GameDataRoot, user)
	gamesDir := filepath.Join(uRoot, "lynrummy-elm", "sessions")
	puzzlesDir := filepath.Join(uRoot, "puzzle", "sessions")

	st := UserStats{
		ID:             user,
		Name:           GetUserName(user),
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
