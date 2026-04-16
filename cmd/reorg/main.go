// cmd/reorg — batch Go package mover.
//
// Reads a script of `mv src/ dst/` lines and executes them as
// Go-aware package moves: rewrites import paths across all .go files,
// updates package declarations, then moves the directories.
//
// Usage:
//   go run cmd/reorg/main.go REORG          # dry-run (default)
//   go run cmd/reorg/main.go --execute REORG # apply for real
//
// Script syntax:
//   # Comments and blank lines are ignored.
//   mv auth/ core/auth/
//   mv ratelimit/ internal/ratelimit/
//
// Each line moves a directory (Go package). The tool infers the old
// and new import paths from the module name in go.mod.
//
// Dry-run output shows every file that would be touched and every
// import that would be rewritten. Execute mode applies the changes
// and runs `go build ./...` to verify.

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type move struct {
	src    string // e.g. "auth"
	dst    string // e.g. "core/auth"
	oldPkg string // e.g. "angry-gopher/auth"
	newPkg string // e.g. "angry-gopher/core/auth"
	line   int
}

type rewrite struct {
	file   string
	old    string
	new    string
	kind   string // "import" or "package"
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
	if modPath == "" {
		fmt.Fprintln(os.Stderr, "error: cannot find module path in go.mod")
		os.Exit(1)
	}

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

	// Scan all .go files for import rewrites needed.
	goFiles := findGoFiles(".")
	var rewrites []rewrite
	for _, f := range goFiles {
		rw := scanFile(f, moves)
		rewrites = append(rewrites, rw...)
	}

	// Report.
	fmt.Printf("Module: %s\n", modPath)
	fmt.Printf("Moves:  %d\n", len(moves))
	fmt.Printf("Files scanned: %d\n", len(goFiles))
	fmt.Printf("Rewrites needed: %d\n", len(rewrites))
	fmt.Println()

	for _, m := range moves {
		fmt.Printf("  mv %-30s → %s\n", m.src+"/", m.dst+"/")
		fmt.Printf("     import: %q → %q\n", m.oldPkg, m.newPkg)
	}
	fmt.Println()

	if len(rewrites) > 0 {
		fmt.Println("Import rewrites:")
		for _, rw := range rewrites {
			fmt.Printf("  %-50s  %s: %q → %q\n", rw.file, rw.kind, rw.old, rw.new)
		}
		fmt.Println()
	}

	// Also check for package declaration changes in moved files.
	var pkgRewrites []rewrite
	for _, m := range moves {
		oldBase := filepath.Base(m.src)
		newBase := filepath.Base(m.dst)
		if oldBase != newBase {
			movedFiles := findGoFilesIn(m.src)
			for _, f := range movedFiles {
				pkgRewrites = append(pkgRewrites, rewrite{
					file: f,
					old:  oldBase,
					new:  newBase,
					kind: "package",
				})
			}
		}
	}
	if len(pkgRewrites) > 0 {
		fmt.Println("Package declaration rewrites:")
		for _, rw := range pkgRewrites {
			fmt.Printf("  %-50s  package %s → %s\n", rw.file, rw.old, rw.new)
		}
		fmt.Println()
	}

	if !execute {
		fmt.Println("DRY RUN — pass --execute to apply.")
		return
	}

	// Execute: rewrite imports, then move dirs.
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

	// Rewrite package declarations in moved files.
	for _, rw := range pkgRewrites {
		newPath := strings.Replace(rw.file, filepath.Dir(rw.file), "", 1)
		// Find the file at its new location.
		for _, m := range moves {
			if strings.HasPrefix(rw.file, m.src) {
				newFile := strings.Replace(rw.file, m.src, m.dst, 1)
				rw.file = newFile
				break
			}
		}
		if err := applyRewrite(rw); err != nil {
			fmt.Fprintf(os.Stderr, "error rewriting package in %s: %v\n", newPath, err)
		}
	}

	// Verify build.
	fmt.Println("\nRunning go build ./...")
	cmd := exec.Command("go", "build", "./...")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "\n⚠ Build failed — check the output above.")
		os.Exit(1)
	}
	fmt.Println("✓ Build succeeded.")
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
		if len(parts) != 3 || parts[0] != "mv" {
			return nil, fmt.Errorf("line %d: expected 'mv src/ dst/', got: %s", lineNum, line)
		}
		src := strings.TrimSuffix(parts[1], "/")
		dst := strings.TrimSuffix(parts[2], "/")
		moves = append(moves, move{
			src:    src,
			dst:    dst,
			oldPkg: modPath + "/" + src,
			newPkg: modPath + "/" + dst,
			line:   lineNum,
		})
	}
	return moves, scanner.Err()
}

// --- Scanning ---

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

var importRE = regexp.MustCompile(`"([^"]+)"`)

func scanFile(path string, moves []move) []rewrite {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	content := string(data)
	var rws []rewrite
	for _, m := range moves {
		// Match exact package AND any sub-packages (e.g. lynrummy/tricks).
		// We scan for all quoted import paths that start with the old path.
		for _, match := range importRE.FindAllString(content, -1) {
			imp := match[1 : len(match)-1] // strip quotes
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
	default:
		return fmt.Errorf("unknown rewrite kind: %s", rw.kind)
	}
	if newContent == content {
		return nil
	}
	return os.WriteFile(rw.file, []byte(newContent), 0644)
}
