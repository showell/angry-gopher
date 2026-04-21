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
//   # Elm move: rewrites module names + qualified references.
//   # Auto-detects the Elm project root via the nearest elm.json
//   # walking up from the source path.
//   elm-mv games/lynrummy/elm/src/LynRummy/ games/lynrummy/elm/src/Game/
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
	elmProjectRoot string // e.g. "games/lynrummy/elm"
	oldModulePrefix string // e.g. "LynRummy"
	newModulePrefix string // e.g. "Game"
}

type rewrite struct {
	file string
	old  string
	new  string
	kind string // "import" | "package" | "elm-module" | "elm-ref"
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
		fmt.Printf("  [%s] mv %-50s → %s\n", m.kind, m.src+"/", m.dst+"/")
		switch m.kind {
		case kindGo:
			fmt.Printf("        import: %q → %q\n", m.oldPkg, m.newPkg)
		case kindElm:
			fmt.Printf("        module: %s.* → %s.*  (project root: %s)\n",
				m.oldModulePrefix, m.newModulePrefix, m.elmProjectRoot)
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

	fmt.Println("Moving directories...")
	for _, m := range moves {
		parent := filepath.Dir(m.dst)
		if parent != "." {
			os.MkdirAll(parent, 0755)
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
func makeElmMove(src, dst string, line int) (move, error) {
	root, err := findElmProjectRoot(src)
	if err != nil {
		return move{}, fmt.Errorf("line %d: %v", line, err)
	}
	dstRoot, err := findElmProjectRoot(filepath.Dir(dst) + "/")
	if err == nil && dstRoot != root {
		return move{}, fmt.Errorf("line %d: elm-mv source and destination must live in the same Elm project", line)
	}

	sourceDirs, err := readElmSourceDirs(root)
	if err != nil {
		return move{}, fmt.Errorf("line %d: reading elm.json in %s: %v", line, root, err)
	}

	oldPrefix, err := modulePrefixFor(src, root, sourceDirs)
	if err != nil {
		return move{}, fmt.Errorf("line %d: src %q: %v", line, src, err)
	}
	newPrefix, err := modulePrefixFor(dst, root, sourceDirs)
	if err != nil {
		return move{}, fmt.Errorf("line %d: dst %q: %v", line, dst, err)
	}
	if oldPrefix == newPrefix {
		return move{}, fmt.Errorf("line %d: computed module prefix did not change (%q)", line, oldPrefix)
	}

	return move{
		kind:            kindElm,
		src:             src,
		dst:             dst,
		elmProjectRoot:  root,
		oldModulePrefix: oldPrefix,
		newModulePrefix: newPrefix,
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
// prefix appears as a qualified reference. Pattern:
// `\boldPrefix(?=\.[A-Z])` — so `LynRummy` in `import LynRummy.Card`,
// `module LynRummy.Card ...`, and `LynRummy.Card.foo` all match.
// A bare word `LynRummy` in a comment (no following dot-uppercase)
// does NOT match.
func scanElmFile(path string, m move) []rewrite {
	if m.kind != kindElm {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	content := string(data)
	re := elmRefRegex(m.oldModulePrefix)
	matches := re.FindAllString(content, -1)
	if len(matches) == 0 {
		return nil
	}
	// Deduplicate for readability in the dry-run report.
	seen := map[string]bool{}
	var rws []rewrite
	for _, match := range matches {
		if seen[match] {
			continue
		}
		seen[match] = true
		rws = append(rws, rewrite{
			file: path,
			old:  match,
			new:  m.newModulePrefix + match[len(m.oldModulePrefix):],
			kind: "elm-ref",
		})
	}
	return rws
}

// elmRefRegex matches `<prefix>` when immediately followed by
// either a dotted uppercase component chain (e.g. `Game.Card` or
// `Game.Tricks.Hint`) OR a literal `.*` (the "Game.*" wildcard
// shorthand common in sidecars). Word-boundary at the start
// avoids matching inside an identifier like `MyGame`.
func elmRefRegex(prefix string) *regexp.Regexp {
	escaped := regexp.QuoteMeta(prefix)
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
	default:
		return fmt.Errorf("unknown rewrite kind: %s", rw.kind)
	}
	if newContent == content {
		return nil
	}
	return os.WriteFile(rw.file, []byte(newContent), 0644)
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
