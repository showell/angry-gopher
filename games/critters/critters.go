// Package critters manages critter-study definitions and telemetry.
// Studies are authored as DSL files in critters/studies/*.claude and
// played through the Elm engine in ~/showell_repos/elm-critters.
// Telemetry (session recordings) lands in the critter_sessions table.
package critters

import (
	"database/sql"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var DB *sql.DB

// Study is the minimal metadata a portal needs to list a study.
// Full DSL is parsed by the Elm engine; Gopher just needs the index.
type Study struct {
	Name  string // filename without .claude; stable id
	Title string // human title from `title:` line
	Desc  string // from `desc:` line
}

// LoadStudies reads critters/studies/*.claude and extracts minimal
// metadata. Returns in name order.
func LoadStudies(dir string) []Study {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []Study
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".claude") {
			continue
		}
		s := parseStudyHeader(filepath.Join(dir, e.Name()))
		s.Name = strings.TrimSuffix(e.Name(), ".claude")
		if s.Title == "" {
			s.Title = s.Name
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// parseStudyHeader scans the first ~30 lines for title/desc.
// The DSL is richer; Gopher doesn't need to parse the rest.
func parseStudyHeader(path string) Study {
	data, err := os.ReadFile(path)
	if err != nil {
		return Study{}
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) > 30 {
		lines = lines[:30]
	}
	var s Study
	for _, ln := range lines {
		ln = strings.TrimSpace(ln)
		if v, ok := kv(ln, "title:"); ok {
			s.Title = v
		} else if v, ok := kv(ln, "desc:"); ok {
			s.Desc = v
		}
	}
	return s
}

func kv(line, key string) (string, bool) {
	if !strings.HasPrefix(line, key) {
		return "", false
	}
	return strings.TrimSpace(line[len(key):]), true
}

// HandleSaveRecording handles POST /gopher/critters/save_recording.
// Accepts the telemetry payload from the Elm game's saveRecording port
// and stores it as one row in critter_sessions.
func HandleSaveRecording(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 2<<20)) // 2MB cap
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	// Pull study + label out of the JSON payload for indexing.
	var head struct {
		Study   string `json:"study"`
		Label   string `json:"label"`
		SavedAt string `json:"saved_at"`
	}
	_ = json.Unmarshal(body, &head) // best-effort; keep the raw body even if parse fails
	savedAt := head.SavedAt
	if savedAt == "" {
		savedAt = time.Now().UTC().Format(time.RFC3339)
	}
	study := head.Study
	if study == "" {
		study = "unknown"
	}

	_, err = DB.Exec(
		`INSERT INTO critter_sessions (study, label, saved_at, payload) VALUES (?, ?, ?, ?)`,
		study, head.Label, savedAt, string(body),
	)
	if err != nil {
		log.Printf("[critters] save_recording insert failed: %v", err)
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
