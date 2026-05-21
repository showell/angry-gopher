// Admin screen: a read-only filesystem view of how much session
// data each player has generated. No DB — it walks
// {GameDataRoot}/{user}/ directly, which is also the on-disk
// partition layout (one top-level dir per user).
package views

import (
	"fmt"
	"html"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
)

// UserStats is a per-player rollup of on-disk session data.
type UserStats struct {
	Name           string
	GameSessions   int
	PuzzleSessions int
	TotalActions   int
	DiskBytes      int64
}

// HandleAdmin renders the admin overview at /admin.
func HandleAdmin(w http.ResponseWriter, r *http.Request) {
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

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 820px; }
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
</style>
</head><body>
<nav><a href="/">← Home</a></nav>
<h1>🐹 Angry Gopher Admin</h1>
<p class="muted">Sessions generated per player. Read straight from %s.</p>
<table>
<tr><th>Player</th><th class="n">Games</th><th class="n">Puzzles</th><th class="n">Actions</th><th class="n">Disk</th></tr>`,
		html.EscapeString(GameDataRoot))

	if len(rows) == 0 {
		fmt.Fprint(w, `<tr><td colspan="5" class="muted">No players yet.</td></tr>`)
	}
	for _, st := range rows {
		writeStatsRow(w, st, "")
	}
	if len(rows) > 1 {
		writeStatsRow(w, grand, "total")
	}
	fmt.Fprint(w, `</table></body></html>`)
}

func writeStatsRow(w http.ResponseWriter, st UserStats, cls string) {
	rowClass := ""
	if cls != "" {
		rowClass = ` class="` + cls + `"`
	}
	fmt.Fprintf(w,
		`<tr%s><td>%s</td><td class="n">%d</td><td class="n">%d</td><td class="n">%d</td><td class="n">%s</td></tr>`,
		rowClass, html.EscapeString(st.Name), st.GameSessions, st.PuzzleSessions,
		st.TotalActions, humanBytes(st.DiskBytes))
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
