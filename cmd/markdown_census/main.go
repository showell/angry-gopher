// markdown_census walks a chat data tree (the .md session transcripts),
// parses every message body with the REAL chat markdown parser, and tallies
// the goldmark AST node kinds that actually occur. This is the "horse's
// mouth" census for the zig port: instead of regex-guessing features, we
// ask goldmark itself what each message parses to.
//
// Usage: markdown_census [chat-root]
// Default root is ~/AngryGopher/corpus-work/prod/chat (a private extract of
// the prod backup; see ops/backup). Pure read; never writes the corpus.
package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"angry-gopher/server/chat"

	"github.com/yuin/goldmark/ast"
)

var tagRe = regexp.MustCompile(`</?([a-zA-Z][\w-]*)`)

func main() {
	root := filepath.Join(os.Getenv("HOME"), "AngryGopher/corpus-work/prod/chat")
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	// Only session transcripts: the per-user images.md/code.md use a
	// different on-disk format, and users/<id>/docs/*.md are raw docs, not
	// message logs. The server only ever decodeChatFile's sessions/<sid>.md.
	var files []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".md") &&
			strings.Contains(filepath.ToSlash(p), "/sessions/") {
			files = append(files, p)
		}
		return nil
	})
	if len(files) == 0 {
		fmt.Fprintf(os.Stderr, "no .md transcripts under %s\n", root)
		os.Exit(1)
	}

	msgs := 0
	kindMsgs := map[string]int{}  // messages containing >=1 of this kind
	kindNodes := map[string]int{} // total nodes of this kind
	rawTags := map[string]int{}   // raw-HTML tag names actually typed

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, m := range chat.DecodeTranscript(data) {
			if strings.TrimSpace(m.Markdown) == "" {
				continue
			}
			msgs++
			src := []byte(m.Markdown)
			doc := chat.ChatMarkdownAST(m.Markdown)
			seen := map[string]bool{}
			_ = ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
				if !entering {
					return ast.WalkContinue, nil
				}
				key := n.Kind().String()
				switch t := n.(type) {
				case *ast.Document:
					return ast.WalkContinue, nil // not a feature
				case *ast.FencedCodeBlock:
					lang := string(t.Language(src))
					switch {
					case lang == "quote":
						key = "FencedCode[quote]"
					case lang != "":
						key = "FencedCode[lang]"
					default:
						key = "FencedCode[plain]"
					}
				case *ast.Emphasis:
					if t.Level == 2 {
						key = "Emphasis[bold]"
					} else {
						key = "Emphasis[italic]"
					}
				case *ast.RawHTML:
					for i := 0; i < t.Segments.Len(); i++ {
						seg := t.Segments.At(i)
						scanTags(seg.Value(src), rawTags)
					}
				case *ast.HTMLBlock:
					l := t.Lines()
					for i := 0; i < l.Len(); i++ {
						seg := l.At(i)
						scanTags(seg.Value(src), rawTags)
					}
				}
				kindNodes[key]++
				if !seen[key] {
					seen[key] = true
					kindMsgs[key]++
				}
				return ast.WalkContinue, nil
			})
		}
	}

	fmt.Printf("FULL corpus: %d messages across %d transcripts under\n  %s\n\n", msgs, len(files), root)
	fmt.Printf("%-22s %7s %5s %8s\n", "AST node kind", "msgs", "%", "nodes")
	fmt.Println(strings.Repeat("-", 45))
	for _, k := range sortedByVal(kindMsgs) {
		fmt.Printf("%-22s %7d %4d%% %8d\n", k, kindMsgs[k], 100*kindMsgs[k]/max(msgs, 1), kindNodes[k])
	}

	fmt.Println("\nraw-HTML tags actually typed (the escape question):")
	if len(rawTags) == 0 {
		fmt.Println("  none")
	} else {
		for _, t := range sortedByVal(rawTags) {
			fmt.Printf("  <%s>: %d\n", t, rawTags[t])
		}
	}
}

func scanTags(b []byte, into map[string]int) {
	for _, m := range tagRe.FindAllSubmatch(b, -1) {
		into[strings.ToLower(string(m[1]))]++
	}
}

func sortedByVal(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}
