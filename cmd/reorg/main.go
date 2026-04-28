// cmd/reorg — batch package / module mover.
//
// Reads a script of move lines and executes them as language-aware
// directory moves: for Go, rewrites import paths + package
// declarations across all .go files; for Elm, rewrites `module`
// declarations and any qualified `X.Y` references across all .elm
// files.
//
// Usage:
//   go run cmd/reorg/main.go REORG          # dry-run (default)
//   go run cmd/reorg/main.go --execute REORG # apply for real
//
// Script syntax:
//   # Comments and blank lines are ignored.
//
//   # Go move: rewrites import paths + package declarations.
//   mv auth/ core/auth/
//
//   # Elm directory move: rewrites module names + qualified
//   # references. Auto-detects the Elm project root via the
//   # nearest elm.json walking up from the source path.
//   elm-mv games/lynrummy/elm/src/LynRummy/ games/lynrummy/elm/src/Game/
//
//   # Elm file move (auto-detected when src ends in .elm and is
//   # a file): renames the module declaration in the moved file
//   # and rewrites every importer's bare/aliased/exposing/chain
//   # form. Also moves any sibling .claude sidecar.
//   elm-mv games/lynrummy/elm/src/Game/Card.elm games/lynrummy/elm/src/Game/Rules/Card.elm
//
// Dry-run output shows every file that would be touched and every
// name that would be rewritten. Execute mode applies the changes
// and runs a per-language verification (go build; elm make).

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type moveKind int

const (
	kindGo moveKind = iota
	kindElm
)

func (k moveKind) String() string {
	switch k {
	case kindGo:
		return "go"
	case kindElm:
		return "elm"
	}
	return "?"
}

type move struct {
	kind moveKind
	src  string // e.g. "auth" or "games/lynrummy/elm/src/LynRummy"
	dst  string // e.g. "core/auth" or "games/lynrummy/elm/src/Game"
	line int

	// Go-specific (kindGo only).
	oldPkg string // e.g. "angry-gopher/auth"
	newPkg string // e.g. "angry-gopher/core/auth"

	// Elm-specific (kindElm only).
	elmProjectRoot  string // e.g. "games/lynrummy/elm"
	oldModulePrefix string // e.g. "LynRummy" or "Game.Card"
	newModulePrefix string // e.g. "Game" or "Game.Rules.Card"
	// elmIsFile is true when src/dst end in .elm and src is a
	// file (single-file move). The two flavours differ in:
	//   - what we move: a directory tree vs a .elm + .claude pair
	//   - how rewrites match: directory mode requires `oldPrefix.X`
	//     (a chain or `.*` wildcard); file mode also matches the
	//     bare prefix (e.g. `import Game.Card` with no follow-up
	//     chain) since the file IS the leaf module.
	elmIsFile bool
}

type rewrite struct {
	file string
	old  string
	new  string
	kind string // "import" | "package" | "elm-module" | "elm-ref" | "elm-ref-file"
}

func main() {
	execute := false
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--execute" {
		execute = true
		args = args[1:]
	}
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: reorg [--execute] SCRIPT")
		os.Exit(1)
	}

	modPath := readModulePath()

	moves, err := parseScript(args[0], modPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	if len(moves) == 0 {
		fmt.Println("no moves in script")
		return
	}

	// Validate: sources exist, destinations don't.
	for _, m := range moves {
		if _, err := os.Stat(m.src); os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "error line %d: source %q does not exist\n", m.line, m.src)
			os.Exit(1)
		}
		if _, err := os.Stat(m.dst); err == nil {
			fmt.Fprintf(os.Stderr, "error line %d: destination %q already exists\n", m.line, m.dst)
			os.Exit(1)
		}
	}

	// Scan for rewrites.
	var rewrites []rewrite
	var pkgRewrites []rewrite

	goMoves := movesOfKind(moves, kindGo)
	if len(goMoves) > 0 {
		for _, f := range findGoFiles(".") {
			rewrites = append(rewrites, scanGoFile(f, goMoves)...)
		}
		pkgRewrites = scanGoPackageRewrites(goMoves)
	}

	// Elm moves may share a project root and an identical
	// old→new prefix (e.g. src/LynRummy/→src/Game/ plus
	// tests/LynRummy/→tests/Game/). Scanning once per move
	// would produce duplicate rewrite rows in the report and
	// no-op duplicate writes on execute. Scan each unique
	// (root, oldPrefix, newPrefix) combo once.
	scannedElm := map[string]bool{}
	for _, m := range moves {
		if m.kind != kindElm {
			continue
		}
		key := m.elmProjectRoot + "|" + m.oldModulePrefix + "→" + m.newModulePrefix
		if scannedElm[key] {
			continue
		}
		scannedElm[key] = true
		for _, f := range findElmFiles(m.elmProjectRoot) {
			rewrites = append(rewrites, scanElmFile(f, m)...)
		}
	}

	// Report.
	if modPath != "" {
		fmt.Printf("Go module: %s\n", modPath)
	}
	fmt.Printf("Moves:  %d  (go=%d, elm=%d)\n", len(moves), len(goMoves), len(moves)-len(goMoves))
	fmt.Printf("Rewrites needed: %d\n", len(rewrites))
	fmt.Println()

	for _, m := range moves {
		srcDisp, dstDisp := m.src, m.dst
		if !(m.kind == kindElm && m.elmIsFile) {
			srcDisp += "/"
			dstDisp += "/"
		}
		fmt.Printf("  [%s] mv %-50s → %s\n", m.kind, srcDisp, dstDisp)
		switch m.kind {
		case kindGo:
			fmt.Printf("        import: %q → %q\n", m.oldPkg, m.newPkg)
		case kindElm:
			if m.elmIsFile {
				fmt.Printf("        module: %s → %s  (file move; project root: %s)\n",
					m.oldModulePrefix, m.newModulePrefix, m.elmProjectRoot)
			} else {
				fmt.Printf("        module: %s.* → %s.*  (project root: %s)\n",
					m.oldModulePrefix, m.newModulePrefix, m.elmProjectRoot)
			}
		}
	}
	fmt.Println()

	if len(rewrites) > 0 {
		fmt.Println("Rewrites:")
		for _, rw := range rewrites {
			fmt.Printf("  %-60s  %s: %q → %q\n", rw.file, rw.kind, rw.old, rw.new)
		}
		fmt.Println()
	}
	if len(pkgRewrites) > 0 {
		fmt.Println("Go package declaration rewrites (applied post-move):")
		for _, rw := range pkgRewrites {
			fmt.Printf("  %-60s  package %s → %s\n", rw.file, rw.old, rw.new)
		}
		fmt.Println()
	}

	if !execute {
		fmt.Println("DRY RUN — pass --execute to apply.")
		return
	}

	// Execute.
	fmt.Println("Applying rewrites...")
	for _, rw := range rewrites {
		if err := applyRewrite(rw); err != nil {
			fmt.Fprintf(os.Stderr, "error rewriting %s: %v\n", rw.file, err)
			os.Exit(1)
		}
	}

	fmt.Println("Moving paths...")
	for _, m := range moves {
		parent := filepath.Dir(m.dst)
		if parent != "." {
			os.MkdirAll(parent, 0755)
		}
		if m.kind == kindElm && m.elmIsFile {
			// File-level Elm move: git mv the .elm file and
			// (if present) its sibling .claude sidecar. git mv
			// keeps git's rename-detection clean and stages
			// the move atomically with the rewrites.
			if err := gitMv(m.src, m.dst); err != nil {
				fmt.Fprintf(os.Stderr, "error git mv %s → %s: %v\n", m.src, m.dst, err)
				os.Exit(1)
			}
			fmt.Printf("  git mv %s → %s\n", m.src, m.dst)
			srcSidecar := strings.TrimSuffix(m.src, ".elm") + ".claude"
			dstSidecar := strings.TrimSuffix(m.dst, ".elm") + ".claude"
			if _, err := os.Stat(srcSidecar); err == nil {
				if err := gitMv(srcSidecar, dstSidecar); err != nil {
					fmt.Fprintf(os.Stderr, "error git mv %s → %s: %v\n", srcSidecar, dstSidecar, err)
					os.Exit(1)
				}
				fmt.Printf("  git mv %s → %s\n", srcSidecar, dstSidecar)
			}
			continue
		}
		if err := os.Rename(m.src, m.dst); err != nil {
			fmt.Fprintf(os.Stderr, "error moving %s → %s: %v\n", m.src, m.dst, err)
			os.Exit(1)
		}
		fmt.Printf("  moved %s → %s\n", m.src, m.dst)
	}

	// Rewrite Go package declarations in moved files (paths are
	// now under their new locations).
	for _, rw := range pkgRewrites {
		for _, m := range goMoves {
			if strings.HasPrefix(rw.file, m.src) {
				rw.file = strings.Replace(rw.file, m.src, m.dst, 1)
				break
			}
		}
		if err := applyRewrite(rw); err != nil {
			fmt.Fprintf(os.Stderr, "error rewriting package in %s: %v\n", rw.file, err)
		}
	}

	// Verify.
	if len(goMoves) > 0 {
		fmt.Println("\nRunning go build ./...")
		cmd := exec.Command("go", "build", "./...")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintln(os.Stderr, "\n⚠ Go build failed — check the output above.")
			os.Exit(1)
		}
		fmt.Println("✓ Go build succeeded.")
	}

	verifiedElmRoots := map[string]bool{}
	for _, m := range moves {
		if m.kind != kindElm {
			continue
		}
		if verifiedElmRoots[m.elmProjectRoot] {
			continue
		}
		verifiedElmRoots[m.elmProjectRoot] = true
		if err := verifyElm(m.elmProjectRoot); err != nil {
			fmt.Fprintf(os.Stderr, "\n⚠ Elm verify failed in %s: %v\n", m.elmProjectRoot, err)
			os.Exit(1)
		}
		fmt.Printf("✓ Elm verify succeeded in %s.\n", m.elmProjectRoot)
	}
}

// --- Parsing ---

func readModulePath() string {
	data, err := os.ReadFile("go.mod")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module "))
		}
	}
	return ""
}

func parseScript(path, modPath string) ([]move, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var moves []move
	scanner := bufio.NewScanner(f)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) != 3 {
			return nil, fmt.Errorf("line %d: expected 'mv src/ dst/' or 'elm-mv src/ dst/', got: %s", lineNum, line)
		}
		verb, src, dst := parts[0], parts[1], parts[2]
		src = strings.TrimSuffix(src, "/")
		dst = strings.TrimSuffix(dst, "/")

		switch verb {
		case "mv":
			if modPath == "" {
				return nil, fmt.Errorf("line %d: 'mv' needs a go.mod; use 'elm-mv' for Elm moves", lineNum)
			}
			moves = append(moves, move{
				kind:   kindGo,
				src:    src,
				dst:    dst,
				oldPkg: modPath + "/" + src,
				newPkg: modPath + "/" + dst,
				line:   lineNum,
			})
		case "elm-mv":
			m, err := makeElmMove(src, dst, lineNum)
			if err != nil {
				return nil, err
			}
			moves = append(moves, m)
		default:
			return nil, fmt.Errorf("line %d: unknown verb %q (want 'mv' or 'elm-mv')", lineNum, verb)
		}
	}
	return moves, scanner.Err()
}

func movesOfKind(moves []move, kind moveKind) []move {
	var out []move
	for _, m := range moves {
		if m.kind == kind {
			out = append(out, m)
		}
	}
	return out
}

// --- Elm move prep ---

// makeElmMove locates the nearest elm.json above src, resolves the
// source-directory the path lives under, and derives the old/new
// dotted module prefix from that.
//
// Auto-detects file-vs-directory: if src ends in .elm AND exists as
// a regular file, the move is treated as a single-file rename
// (e.g. Game/Card.elm → Game/Rules/Card.elm). dst must then also
// end in .elm.
func makeElmMove(src, dst string, line int) (move, error) {
	srcInfo, statErr := os.Stat(src)
	isFile := false
	if statErr == nil && !srcInfo.IsDir() && strings.HasSuffix(src, ".elm") {
		isFile = true
	}
	if isFile && !strings.HasSuffix(dst, ".elm") {
		return move{}, fmt.Errorf("line %d: elm-mv file source %q requires a .elm destination, got %q", line, src, dst)
	}
	// If src looks .elm-shaped but isn't a regular file, fall
	// through. main()'s existence check produces the clearer
	// error message ("source %q does not exist").
	_ = statErr

	// For file moves, walk up from the file's parent dir to find
	// elm.json; for directory moves the existing behavior (walk
	// from src itself) is right.
	startForRoot := src
	if isFile {
		startForRoot = filepath.Dir(src) + "/"
	}
	root, err := findElmProjectRoot(startForRoot)
	if err != nil {
		return move{}, fmt.Errorf("line %d: %v", line, err)
	}
	dstParent := filepath.Dir(dst)
	if dstParent == "" || dstParent == "." {
		dstParent = "."
	}
	dstRoot, err := findElmProjectRoot(dstParent + "/")
	if err == nil && dstRoot != root {
		return move{}, fmt.Errorf("line %d: elm-mv source and destination must live in the same Elm project", line)
	}

	sourceDirs, err := readElmSourceDirs(root)
	if err != nil {
		return move{}, fmt.Errorf("line %d: reading elm.json in %s: %v", line, root, err)
	}

	// For file moves the prefix is derived from the path with the
	// .elm suffix stripped — that gives the full dotted module
	// name (e.g. src/Game/Card.elm → "Game.Card").
	srcForPrefix := src
	dstForPrefix := dst
	if isFile {
		srcForPrefix = strings.TrimSuffix(src, ".elm")
		dstForPrefix = strings.TrimSuffix(dst, ".elm")
	}

	oldPrefix, err := modulePrefixFor(srcForPrefix, root, sourceDirs)
	if err != nil {
		return move{}, fmt.Errorf("line %d: src %q: %v", line, src, err)
	}
	newPrefix, err := modulePrefixFor(dstForPrefix, root, sourceDirs)
	if err != nil {
		return move{}, fmt.Errorf("line %d: dst %q: %v", line, dst, err)
	}
	if oldPrefix == newPrefix {
		return move{}, fmt.Errorf("line %d: computed module prefix did not change (%q)", line, oldPrefix)
	}

	// File-mode safety check: if a sibling directory with the same
	// stem exists (e.g. moving Game/Card.elm while Game/Card/
	// also exists as a sub-tree), the bare-prefix regex would
	// rewrite references to those submodules too — which is
	// wrong. Refuse and ask the user to disambiguate.
	if isFile {
		stemDir := strings.TrimSuffix(src, ".elm")
		if info, err := os.Stat(stemDir); err == nil && info.IsDir() {
			return move{}, fmt.Errorf(
				"line %d: refusing file move: sibling directory %q exists; "+
					"a file move would also rewrite references to its submodules. "+
					"Move the directory first, or move both together explicitly.",
				line, stemDir)
		}
	}

	return move{
		kind:            kindElm,
		src:             src,
		dst:             dst,
		elmProjectRoot:  root,
		oldModulePrefix: oldPrefix,
		newModulePrefix: newPrefix,
		elmIsFile:       isFile,
		line:            line,
	}, nil
}

// findElmProjectRoot walks upward from a path looking for elm.json.
// Returns the directory containing it.
func findElmProjectRoot(start string) (string, error) {
	clean := filepath.Clean(start)
	// Walk up from the closest existing ancestor.
	dir := clean
	for {
		if _, err := os.Stat(filepath.Join(dir, "elm.json")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no elm.json found above %q", start)
		}
		dir = parent
	}
}

// readElmSourceDirs returns the paths elm considers module roots:
// the "source-directories" entries from elm.json PLUS "tests" when
// a tests/ directory exists (elm-test's convention — tests/ is a
// de-facto source-dir at test time).
func readElmSourceDirs(root string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(root, "elm.json"))
	if err != nil {
		return nil, err
	}
	var doc struct {
		SourceDirectories []string `json:"source-directories"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	out := []string{}
	for _, d := range doc.SourceDirectories {
		d = strings.TrimPrefix(d, "./")
		d = strings.TrimSuffix(d, "/")
		out = append(out, d)
	}
	if len(out) == 0 {
		out = append(out, "src")
	}
	// tests/ is a source-dir by elm-test convention, even if
	// elm.json doesn't list it.
	if _, err := os.Stat(filepath.Join(root, "tests")); err == nil {
		hasTests := false
		for _, d := range out {
			if d == "tests" {
				hasTests = true
				break
			}
		}
		if !hasTests {
			out = append(out, "tests")
		}
	}
	return out, nil
}

// modulePrefixFor converts a directory path like
// "games/lynrummy/elm/src/LynRummy" into the dotted module prefix
// "LynRummy", using the Elm project root and source-directories to
// strip the non-module portion.
func modulePrefixFor(dirPath, root string, sourceDirs []string) (string, error) {
	rel, err := filepath.Rel(root, dirPath)
	if err != nil {
		return "", err
	}
	rel = filepath.ToSlash(rel)
	for _, sd := range sourceDirs {
		sd = filepath.ToSlash(sd)
		if rel == sd {
			return "", fmt.Errorf("path equals source-directory %q; no module prefix", sd)
		}
		if strings.HasPrefix(rel, sd+"/") {
			inside := strings.TrimPrefix(rel, sd+"/")
			if inside == "" {
				return "", fmt.Errorf("empty module prefix for %q", dirPath)
			}
			return strings.ReplaceAll(inside, "/", "."), nil
		}
	}
	return "", fmt.Errorf("path %q is not under any source-directory in elm.json (%v)", dirPath, sourceDirs)
}

// --- Go scanning ---

var importRE = regexp.MustCompile(`"([^"]+)"`)

func findGoFiles(root string) []string {
	var files []string
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		name := info.Name()
		if info.IsDir() {
			if name == ".git" || name == "node_modules" || name == "elm-stuff" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(name, ".go") {
			files = append(files, path)
		}
		return nil
	})
	return files
}

func findGoFilesIn(dir string) []string {
	var files []string
	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if strings.HasSuffix(info.Name(), ".go") {
			files = append(files, path)
		}
		return nil
	})
	return files
}

func scanGoFile(path string, moves []move) []rewrite {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	content := string(data)
	var rws []rewrite
	for _, m := range moves {
		for _, match := range importRE.FindAllString(content, -1) {
			imp := match[1 : len(match)-1]
			if imp == m.oldPkg || strings.HasPrefix(imp, m.oldPkg+"/") {
				newImp := m.newPkg + imp[len(m.oldPkg):]
				rws = append(rws, rewrite{
					file: path,
					old:  imp,
					new:  newImp,
					kind: "import",
				})
			}
		}
	}
	return rws
}

func scanGoPackageRewrites(moves []move) []rewrite {
	var out []rewrite
	for _, m := range moves {
		oldBase := filepath.Base(m.src)
		newBase := filepath.Base(m.dst)
		if oldBase == newBase {
			continue
		}
		for _, f := range findGoFilesIn(m.src) {
			out = append(out, rewrite{
				file: f,
				old:  oldBase,
				new:  newBase,
				kind: "package",
			})
		}
	}
	return out
}

// --- Elm scanning ---

// findElmFiles returns every file whose contents may legitimately
// reference an Elm module name: .elm sources AND .claude sidecars.
// Sidecars use module-qualified names just like source code does
// (`LynRummy.Reducer`, `Main.Apply.applyAction`, etc.), so they
// need the same rewrite sweep.
func findElmFiles(root string) []string {
	var files []string
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		name := info.Name()
		if info.IsDir() {
			if name == "elm-stuff" || name == "node_modules" || name == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(name, ".elm") || strings.HasSuffix(name, ".claude") {
			files = append(files, path)
		}
		return nil
	})
	return files
}

// scanElmFile records every place in path where the old module
// prefix appears as a qualified reference.
//
// Directory-move pattern: `\boldPrefix(?=\.[A-Z])` — so
// `LynRummy` in `import LynRummy.Card`, `module LynRummy.Card`,
// and `LynRummy.Card.foo` all match. A bare word `LynRummy` in a
// comment (no following dot-uppercase) does NOT match.
//
// File-move pattern: also matches the bare prefix as a complete
// module name. `import Game.Card`, `import Game.Card as C`,
// `import Game.Card exposing (Card)`, and submodule chains like
// `Game.Card.foo` all match. The prefix is anchored on both
// sides so `Game.Cards` (different module) does not match.
func scanElmFile(path string, m move) []rewrite {
	if m.kind != kindElm {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	content := string(data)
	re := elmRefRegex(m.oldModulePrefix, m.elmIsFile)
	matches := re.FindAllString(content, -1)
	if len(matches) == 0 {
		return nil
	}
	// Deduplicate for readability in the dry-run report.
	seen := map[string]bool{}
	var rws []rewrite
	kind := "elm-ref"
	if m.elmIsFile {
		// File mode rewrites need word-boundary-aware
		// replacement (so `Game.Card` in `Game.Cards` is
		// untouched). The applier dispatches on this kind to
		// use a regex instead of `strings.ReplaceAll`.
		kind = "elm-ref-file"
	}
	for _, match := range matches {
		if seen[match] {
			continue
		}
		seen[match] = true
		rws = append(rws, rewrite{
			file: path,
			old:  match,
			new:  m.newModulePrefix + match[len(m.oldModulePrefix):],
			kind: kind,
		})
	}
	return rws
}

// elmRefRegex builds the per-mode reference matcher.
//
// Directory mode: matches `<prefix>` only when followed by a
// dotted uppercase chain (`.Card.Something`) or `.*` (wildcard).
// A bare prefix without a chain is left alone — that's the
// "prose mention of the game's name" carve-out.
//
// File mode: matches the bare prefix as a complete module
// reference, anchored on both sides by `\b`. The prefix's last
// segment ends in an identifier char (e.g. `Card`); `\b` then
// matches against any following non-identifier character or
// end-of-string. This admits `import Game.Card`, `import
// Game.Card as C`, `import Game.Card exposing (...)`, and chains
// `Game.Card.foo` / `Game.Card.subThing` uniformly. It rejects
// continuations into a different word: `Game.Cards` (followed by
// `s`, a word char) does not match.
func elmRefRegex(prefix string, isFile bool) *regexp.Regexp {
	escaped := regexp.QuoteMeta(prefix)
	if isFile {
		// `\b<prefix>\b` — Go's RE2 lacks lookahead, but \b is a
		// zero-width word boundary that gives the same effect:
		// the prefix must be followed by a non-word char (incl.
		// `.`) or EOS, never by another identifier char.
		return regexp.MustCompile(`\b` + escaped + `\b`)
	}
	// Two alternatives: `.Card.Something` (identifier chain) OR
	// `.*` (wildcard). The identifier branch ends at `\b` so
	// `Card0` isn't clipped to `Card`.
	return regexp.MustCompile(
		`\b` + escaped + `(?:\.\*|\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\b)`,
	)
}

// --- Applying ---

func applyRewrite(rw rewrite) error {
	data, err := os.ReadFile(rw.file)
	if err != nil {
		return err
	}
	content := string(data)
	var newContent string
	switch rw.kind {
	case "import":
		newContent = strings.ReplaceAll(content,
			`"`+rw.old+`"`,
			`"`+rw.new+`"`,
		)
	case "package":
		newContent = strings.Replace(content,
			"package "+rw.old,
			"package "+rw.new,
			1,
		)
	case "elm-ref":
		// Replace every occurrence of the exact matched string.
		// The scanner dedupes, but applyRewrite may be called
		// once per unique match — so replace ALL.
		newContent = strings.ReplaceAll(content, rw.old, rw.new)
	case "elm-ref-file":
		// File-mode rewrites are word-boundary-anchored: the
		// prefix `Game.Card` must not match inside
		// `Game.Cards`. Use a regex instead of ReplaceAll.
		re := regexp.MustCompile(`\b` + regexp.QuoteMeta(rw.old) + `\b`)
		newContent = re.ReplaceAllString(content, rw.new)
	default:
		return fmt.Errorf("unknown rewrite kind: %s", rw.kind)
	}
	if newContent == content {
		return nil
	}
	return os.WriteFile(rw.file, []byte(newContent), 0644)
}

// --- git mv (file-mode Elm moves) ---

// gitMv runs `git mv src dst`. The parent of dst must already
// exist. Errors if the working tree's git invocation fails.
func gitMv(src, dst string) error {
	parent := filepath.Dir(dst)
	if parent != "." && parent != "" {
		if err := os.MkdirAll(parent, 0755); err != nil {
			return fmt.Errorf("mkdir %s: %v", parent, err)
		}
	}
	cmd := exec.Command("git", "mv", src, dst)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// --- Elm verification ---

// verifyElm runs `elm make src/Main.elm --output=/dev/null` in the
// Elm project root. Uses ./node_modules/.bin/elm if present (the
// pinned local install), otherwise falls back to `elm` on $PATH.
func verifyElm(root string) error {
	// exec.Cmd with Dir set interprets the binary path relative
	// to the NEW working dir, so use "./node_modules/.bin/elm"
	// (not filepath.Join(root, ...)) so the lookup stays correct.
	elmBin := "./node_modules/.bin/elm"
	if _, err := os.Stat(filepath.Join(root, "node_modules", ".bin", "elm")); err != nil {
		elmBin = "elm"
	}
	mainPath := "src/Main.elm"
	if _, err := os.Stat(filepath.Join(root, mainPath)); err != nil {
		return fmt.Errorf("no src/Main.elm in %s to verify with", root)
	}
	fmt.Printf("\nRunning %s make %s --output=/dev/null (in %s)\n", elmBin, mainPath, root)
	cmd := exec.Command(elmBin, "make", mainPath, "--output=/dev/null")
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
