// crudgen: compile .claude DSL files describing Gopher CRUD pages
// into views/*.go handler source.
//
// Opt-in: only files explicitly passed on the CLI are compiled.
// Deleting the .claude file and keeping the .go unstuck a page
// from this pipeline.
//
// Usage:
//   go run ./cmd/crudgen ./views/buddies.claude [...]

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/tools/imports"
)


// --- AST ---

type page struct {
	name      string
	path      string
	nav       string // top-nav label; empty = omit from nav
	title     string
	subtitle  string
	auth      string // "user" | "admin" | "guest"
	adminOnly bool   // mirrors registry.go PageDef.AdminOnly
	handler   string // Go func name, e.g. "HandleBuddies"
	views     []view
	handlers  []handler
}

type view struct {
	name     string
	when     string // "method=GET" today; extend as needed
	preamble *preamble
	table    *tableSpec
	forms    []form

	// Detail-view fields (populated only when view dispatches on
	// a row id, typically `when: id`).
	detailQuery string  // SQL that returns exactly one row
	notFound    string  // 404 message if the query returns none
	heading     string  // <h1> template; may reference row columns
	facts       []fact  // 2-col key/value block
	links       []link  // named anchor links (back, replay, etc.)
	sections    []section
}

type fact struct {
	label   string
	renderer string // "user_link", "user_link_or", "time_short", ...
	args    map[string]string
}

type link struct {
	name string // "back", "replay", etc.
	href string // template — may include {id} etc.
	text string
}

type section struct {
	title string
	table *tableSpec
}

// form is an HTML form rendered inline in a view. The POST is
// delegated to a named handler block elsewhere in the page.
type form struct {
	name         string
	title        string // rendered as <h2>
	submit       string // button text
	hint         string // <span> below the submit, optional
	fields       []field
	handlerName  string // top-level handler block that processes POST
	ownerGate    []string // column names whose value must match $user
	adminOnly    bool
	actionPath   string // override for <form action="...">; empty = auto
}

type preamble struct {
	text    string   // with {name} placeholders
	vars    []namedQuery // named sub-queries filling placeholders
}

type namedQuery struct {
	name string
	sql  string
	kind string // "int" for COUNT etc.; extend as needed
}

type tableSpec struct {
	query   string
	columns []column
	empty   string
}

type column struct {
	header   string
	renderer string // "text" | "toggle_form"
	args     map[string]string
}

type handler struct {
	name       string
	when       string // raw "method=POST id label=1" predicate string
	predicates []predicate
	ownerGate  []string
	adminOnly  bool
	fields     []field
	action     action
	redirect   string
}

// predicate is a single when-clause token. Examples:
//   method=POST    → {kind: "method", value: "POST"}
//   id             → {kind: "has_param", value: "id"}
//   label=1        → {kind: "param_eq", param: "label", value: "1"}
type predicate struct {
	kind  string
	param string
	value string
}

func parseWhen(raw string) []predicate {
	var out []predicate
	for _, tok := range strings.Fields(raw) {
		if eq := strings.Index(tok, "="); eq > 0 {
			k := tok[:eq]
			v := tok[eq+1:]
			if k == "method" {
				out = append(out, predicate{kind: "method", value: v})
			} else {
				out = append(out, predicate{kind: "param_eq", param: k, value: v})
			}
		} else {
			out = append(out, predicate{kind: "has_param", param: tok})
		}
	}
	return out
}

type field struct {
	name     string
	goType   string            // "int" | "string" | "text" | "textarea" | "checkbox" | "hidden"
	required bool
	attrs    map[string]string // value, placeholder, width, etc.
}

type action struct {
	kind  string            // "toggle_row"
	attrs map[string]string // table, match, etc.
}

// --- Entry point ---

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: crudgen <page.claude>...")
		os.Exit(2)
	}
	for _, arg := range os.Args[1:] {
		matches, err := filepath.Glob(arg)
		if err != nil {
			die(err)
		}
		for _, path := range matches {
			if err := compile(path); err != nil {
				die(err)
			}
		}
	}
}

func compile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	p, err := parse(string(data), path)
	if err != nil {
		return err
	}
	out := strings.TrimSuffix(path, ".claude") + ".go"
	src := emitGo(p)
	if err := writeGoFile(out, []byte(src)); err != nil {
		return err
	}

	// Build-gate + idempotence. Any emitter bug surfaces here, not
	// three iterations later when a human runs the tests.
	if err := runGoBuild(); err != nil {
		return fmt.Errorf("%s: generated Go didn't build:\n%w", path, err)
	}
	// Regen once more and compare — catches non-determinism.
	original, _ := os.ReadFile(out)
	src2 := emitGo(p)
	if err := writeGoFile(out, []byte(src2)); err != nil {
		return err
	}
	after, _ := os.ReadFile(out)
	if !bytes.Equal(original, after) {
		return fmt.Errorf("%s: regen not idempotent", path)
	}

	fmt.Printf("Wrote %s (from %s)\n", out, filepath.Base(path))
	return nil
}

// writeGoFile formats + imports-resolves + writes. Emitter emits
// code without an import block; imports.Process adds what's
// needed and runs gofmt.
func writeGoFile(path string, src []byte) error {
	formatted, err := imports.Process(path, src, &imports.Options{
		Comments:  true,
		TabIndent: true,
		TabWidth:  8,
	})
	if err != nil {
		_ = os.WriteFile(path+".raw", src, 0644)
		return fmt.Errorf("goimports: %w (raw saved to %s.raw)", err, path)
	}
	return os.WriteFile(path, formatted, 0644)
}

func runGoBuild() error {
	cmd := exec.Command("go", "build", "./views/...")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s\n%s", err, out)
	}
	return nil
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// --- Lexer (line-oriented, 2-space indent) ---

type line struct {
	indent  int
	content string
	lineNum int
}

func tokenize(src, path string) ([]line, error) {
	var out []line
	for i, raw := range strings.Split(src, "\n") {
		stripped := strings.TrimRight(raw, " \t")
		// Preserve comments only outside of SQL-bodies; we strip # comments
		// at parse time only when they start the line.
		if stripped == "" {
			continue
		}
		indent := 0
		for indent < len(stripped) && stripped[indent] == ' ' {
			indent++
		}
		if indent%2 != 0 {
			return nil, fmt.Errorf("%s:%d: indent must be even", path, i+1)
		}
		trimmed := strings.TrimLeft(stripped, " ")
		// Full-line comment?
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		out = append(out, line{indent: indent / 2, content: trimmed, lineNum: i + 1})
	}
	return out, nil
}

// --- Parser ---

func parse(src, path string) (page, error) {
	lines, err := tokenize(src, path)
	if err != nil {
		return page{}, err
	}
	if len(lines) == 0 || !strings.HasPrefix(lines[0].content, "page ") {
		return page{}, fmt.Errorf("%s: expected 'page <name>' as first line", path)
	}
	p := page{name: strings.TrimPrefix(lines[0].content, "page ")}
	i := 1
	for i < len(lines) {
		l := lines[i]
		if l.indent != 1 {
			return p, fmt.Errorf("%s:%d: expected indent=1", path, l.lineNum)
		}
		key, val, hasBlock := splitKV(l.content)
		i++
		var children []line
		for i < len(lines) && lines[i].indent >= 2 {
			children = append(children, lines[i])
			i++
		}
		if err := applyPageField(&p, key, val, hasBlock, children, path); err != nil {
			return p, err
		}
	}
	if p.handler == "" {
		p.handler = "Handle" + capitalize(p.name)
	}
	return p, nil
}

func applyPageField(p *page, key, val string, hasBlock bool, children []line, path string) error {
	switch key {
	case "path":
		p.path = val
	case "nav":
		p.nav = val
	case "title":
		p.title = val
	case "subtitle":
		p.subtitle = val
	case "auth":
		p.auth = val
		if val == "admin" {
			p.adminOnly = true
		}
	case "admin_only":
		p.adminOnly = val == "true" || val == "1"
	case "handler":
		// "handler: <GoFuncName>" scalar = sets p.handler.
		// "handler <name>" block = defines a POST handler.
		if hasBlock || len(children) > 0 {
			h, err := parseHandler(val, children, path)
			if err != nil {
				return err
			}
			p.handlers = append(p.handlers, h)
		} else {
			p.handler = val
		}
	case "view":
		v, err := parseView(val, children, path)
		if err != nil {
			return err
		}
		p.views = append(p.views, v)
	case "handler_def":
		// reserved for future — not used yet
	default:
		return fmt.Errorf("%s: unknown page field %q", path, key)
	}
	return nil
}

func parseView(name string, children []line, path string) (view, error) {
	v := view{name: name}
	i := 0
	for i < len(children) {
		l := children[i]
		if l.indent != 2 {
			return v, fmt.Errorf("%s:%d: unexpected indent in view", path, l.lineNum)
		}
		key, val, hasBlock := splitKV(l.content)
		i++
		var sub []line
		for i < len(children) && children[i].indent >= 3 {
			sub = append(sub, children[i])
			i++
		}
		_ = hasBlock
		switch key {
		case "when":
			v.when = val
		case "preamble":
			pre, err := parsePreamble(sub, path)
			if err != nil {
				return v, err
			}
			v.preamble = pre
		case "table":
			ts, err := parseTable(sub, path)
			if err != nil {
				return v, err
			}
			v.table = ts
		case "form":
			f, err := parseForm(val, sub, path)
			if err != nil {
				return v, err
			}
			v.forms = append(v.forms, f)
		case "query":
			if val != "" {
				v.detailQuery = val
			} else {
				var parts []string
				for _, s := range sub {
					parts = append(parts, s.content)
				}
				v.detailQuery = strings.Join(parts, " ")
			}
		case "not_found":
			v.notFound = stripQuotes(val)
		case "heading":
			v.heading = stripQuotes(val)
		case "facts":
			facts, err := parseFacts(sub, path)
			if err != nil {
				return v, err
			}
			v.facts = facts
		case "section":
			sec, err := parseSection(val, sub, path)
			if err != nil {
				return v, err
			}
			v.sections = append(v.sections, sec)
		default:
			if strings.HasPrefix(key, "link ") {
				ln, err := parseLink(strings.TrimPrefix(key, "link "), val)
				if err != nil {
					return v, err
				}
				v.links = append(v.links, ln)
			} else {
				return v, fmt.Errorf("%s:%d: unknown view field %q", path, l.lineNum, key)
			}
		}
	}
	return v, nil
}

func parsePreamble(children []line, path string) (*preamble, error) {
	pre := &preamble{}
	for _, l := range children {
		key, val, _ := splitKV(l.content)
		switch key {
		case "text":
			pre.text = stripQuotes(val)
		default:
			// Any other key is a named sub-query.
			pre.vars = append(pre.vars, namedQuery{name: key, sql: val, kind: "int"})
		}
	}
	return pre, nil
}

func parseTable(children []line, path string) (*tableSpec, error) {
	ts := &tableSpec{}
	i := 0
	for i < len(children) {
		l := children[i]
		key, val, hasBlock := splitKV(l.content)
		i++
		var sub []line
		for i < len(children) && children[i].indent > l.indent {
			sub = append(sub, children[i])
			i++
		}
		switch key {
		case "query":
			if hasBlock {
				var parts []string
				for _, s := range sub {
					parts = append(parts, s.content)
				}
				ts.query = strings.Join(parts, " ")
			} else {
				ts.query = val
			}
		case "empty":
			ts.empty = stripQuotes(val)
		case "columns":
			cols, err := parseColumns(sub, path)
			if err != nil {
				return ts, err
			}
			ts.columns = cols
		default:
			return ts, fmt.Errorf("%s:%d: unknown table field %q", path, l.lineNum, key)
		}
	}
	return ts, nil
}

func parseColumns(children []line, path string) ([]column, error) {
	var out []column
	for _, l := range children {
		// "<header>": <renderer>(args)
		hdr, rest, ok := strings.Cut(l.content, ":")
		if !ok {
			return nil, fmt.Errorf("%s:%d: bad column syntax", path, l.lineNum)
		}
		header := stripQuotes(strings.TrimSpace(hdr))
		rest = strings.TrimSpace(rest)
		// parse "name(arg, arg, ...)"
		name, args, err := parseCall(rest)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
		}
		out = append(out, column{header: header, renderer: name, args: args})
	}
	return out, nil
}

// parseFacts parses a "facts:" block — each line is
// `"Label": renderer(args)`.
func parseFacts(children []line, path string) ([]fact, error) {
	var out []fact
	for _, l := range children {
		hdr, rest, ok := strings.Cut(l.content, ":")
		if !ok {
			return nil, fmt.Errorf("%s:%d: bad fact syntax", path, l.lineNum)
		}
		label := stripQuotes(strings.TrimSpace(hdr))
		rest = strings.TrimSpace(rest)
		name, args, err := parseCall(rest)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
		}
		out = append(out, fact{label: label, renderer: name, args: args})
	}
	return out, nil
}

// parseSection parses `section "Title"` with a nested table.
func parseSection(header string, children []line, path string) (section, error) {
	s := section{title: stripQuotes(header)}
	for i := 0; i < len(children); i++ {
		l := children[i]
		key, _, _ := splitKV(l.content)
		if key != "table" {
			continue
		}
		// Collect deeper-indented lines as table's children.
		var sub []line
		i++
		for i < len(children) && children[i].indent > l.indent {
			sub = append(sub, children[i])
			i++
		}
		i--
		ts, err := parseTable(sub, path)
		if err != nil {
			return s, err
		}
		s.table = ts
	}
	return s, nil
}

// parseLink parses `link <name>: <href> text="Display Text"`.
// The name (back/replay/etc.) is purely for grouping; href and
// text are what render.
func parseLink(name, spec string) (link, error) {
	ln := link{name: strings.TrimSpace(name)}
	// Split on whitespace but keep text="..." together.
	parts := splitArgs(spec)
	if len(parts) > 0 {
		// First positional = href.
		firstLine := strings.TrimSpace(parts[0])
		// href may have trailing text="..."; split on the first
		// whitespace after an =".
		if idx := strings.Index(firstLine, " text="); idx > 0 {
			ln.href = strings.TrimSpace(firstLine[:idx])
			ln.text = stripQuotes(strings.TrimSpace(firstLine[idx+len(" text="):]))
		} else {
			ln.href = firstLine
		}
	}
	return ln, nil
}

// parseForm parses a form block. Header syntax: "form <name>"
// optionally followed by a bracketed gate like "[owner: c1, c2]"
// or "[admin: true]" — captured in the name value verbatim and
// split out here.
func parseForm(header string, children []line, path string) (form, error) {
	f := form{}
	f.name, f.ownerGate, f.adminOnly = parseBlockHeaderGate(header)
	for i := 0; i < len(children); i++ {
		l := children[i]
		key, val, hasBlock := splitKV(l.content)
		_ = hasBlock
		switch key {
		case "title":
			f.title = stripQuotes(val)
		case "submit":
			f.submit = stripQuotes(val)
		case "hint":
			f.hint = stripQuotes(val)
		case "handler":
			f.handlerName = val
		case "action":
			f.actionPath = val
		default:
			if strings.HasPrefix(key, "field ") {
				fld, err := parseFormField(strings.TrimPrefix(key, "field "), val)
				if err != nil {
					return f, err
				}
				f.fields = append(f.fields, fld)
			} else {
				return f, fmt.Errorf("%s:%d: unknown form field %q", path, l.lineNum, key)
			}
		}
	}
	return f, nil
}

// parseFormField parses "field <name>: <type> attr=val attr=val".
// Types: text, textarea, checkbox, hidden. Attrs tracked:
// value (initial-value expression), placeholder, width, optional.
func parseFormField(name, spec string) (field, error) {
	f := field{name: name}
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return f, fmt.Errorf("field %q missing type", name)
	}
	f.goType = parts[0]
	f.attrs = map[string]string{}
	for _, p := range parts[1:] {
		if p == "optional" {
			f.required = false
			continue
		}
		if p == "required" {
			f.required = true
			continue
		}
		if eq := strings.Index(p, "="); eq > 0 {
			f.attrs[p[:eq]] = stripQuotes(p[eq+1:])
		}
	}
	return f, nil
}

// parseBlockHeaderGate extracts a "[owner: c1, c2]" or "[admin:
// true]" suffix from a block header like "label [owner: player1_id]".
// Returns the cleaned name, owner columns, and adminOnly flag.
func parseBlockHeaderGate(header string) (name string, ownerCols []string, adminOnly bool) {
	lb := strings.Index(header, "[")
	if lb < 0 {
		return strings.TrimSpace(header), nil, false
	}
	rb := strings.LastIndex(header, "]")
	if rb < 0 || rb < lb {
		return strings.TrimSpace(header), nil, false
	}
	name = strings.TrimSpace(header[:lb])
	inner := header[lb+1 : rb]
	for _, part := range strings.Split(inner, ";") {
		part = strings.TrimSpace(part)
		k, v, _ := strings.Cut(part, ":")
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		switch k {
		case "owner":
			for _, col := range strings.Split(v, ",") {
				col = strings.TrimSpace(col)
				if col != "" {
					ownerCols = append(ownerCols, col)
				}
			}
		case "admin":
			adminOnly = v == "true" || v == "1"
		}
	}
	return name, ownerCols, adminOnly
}

func parseHandler(header string, children []line, path string) (handler, error) {
	name, owner, admin := parseBlockHeaderGate(header)
	h := handler{name: name, ownerGate: owner, adminOnly: admin}
	i := 0
	for i < len(children) {
		l := children[i]
		key, val, hasBlock := splitKV(l.content)
		i++
		var sub []line
		for i < len(children) && children[i].indent > l.indent {
			sub = append(sub, children[i])
			i++
		}
		_ = hasBlock
		switch key {
		case "when":
			h.when = val
			h.predicates = parseWhen(val)
		case "redirect":
			h.redirect = val
		case "action":
			// "action: toggle_row" with children giving attrs
			h.action.kind = strings.TrimSpace(val)
			h.action.attrs = map[string]string{}
			for _, s := range sub {
				k, v, _ := splitKV(s.content)
				h.action.attrs[k] = v
			}
		default:
			// field <name>: type [required]
			if strings.HasPrefix(key, "field ") {
				f, err := parseField(strings.TrimPrefix(key, "field "), val)
				if err != nil {
					return h, err
				}
				h.fields = append(h.fields, f)
			} else {
				return h, fmt.Errorf("%s:%d: unknown handler field %q", path, l.lineNum, key)
			}
		}
	}
	return h, nil
}

func parseField(name, spec string) (field, error) {
	f := field{name: name}
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return f, fmt.Errorf("field %q missing type", name)
	}
	switch parts[0] {
	case "int":
		f.goType = "int"
	case "string":
		f.goType = "string"
	default:
		return f, fmt.Errorf("field %q: unsupported type %q", name, parts[0])
	}
	for _, p := range parts[1:] {
		if p == "required" {
			f.required = true
		}
	}
	return f, nil
}

// --- Helpers ---

func splitKV(s string) (key, val string, hasBlock bool) {
	// Find first colon outside of brackets/parens. Bracketed
	// gates like "[owner: col1, col2]" contain colons that must
	// not be treated as key-value separators.
	idx := firstColonOutsideBrackets(s)
	if idx < 0 {
		// No colon — split first word as key, rest as value.
		// Used for block headers like "view list" / "handler toggle".
		sp := strings.IndexAny(s, " \t")
		if sp < 0 {
			return s, "", true
		}
		return strings.TrimSpace(s[:sp]), strings.TrimSpace(s[sp:]), true
	}
	key = strings.TrimSpace(s[:idx])
	val = strings.TrimSpace(s[idx+1:])
	hasBlock = val == ""
	return
}

func firstColonOutsideBrackets(s string) int {
	depth := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '[', '(':
			depth++
		case ']', ')':
			if depth > 0 {
				depth--
			}
		case ':':
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

func stripQuotes(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}

// parseCall parses "name(arg1=val1, arg2=val2, bareArg)" into
// (name, argsMap) where bare positional args use keys like "_0".
// Deliberately tolerant — the DSL is small and we control inputs.
func parseCall(s string) (string, map[string]string, error) {
	open := strings.Index(s, "(")
	if open < 0 || !strings.HasSuffix(s, ")") {
		return "", nil, fmt.Errorf("bad call syntax: %q", s)
	}
	name := strings.TrimSpace(s[:open])
	inner := s[open+1 : len(s)-1]
	args := map[string]string{}
	posIdx := 0
	for _, part := range splitArgs(inner) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if eq := strings.Index(part, "="); eq > 0 {
			args[strings.TrimSpace(part[:eq])] = strings.TrimSpace(part[eq+1:])
		} else {
			args[fmt.Sprintf("_%d", posIdx)] = part
			posIdx++
		}
	}
	return name, args, nil
}

// splitArgs respects parens/quotes so commas inside calls don't split.
func splitArgs(s string) []string {
	var out []string
	depth := 0
	start := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	out = append(out, s[start:])
	return out
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	b := []byte(s)
	b[0] = b[0] &^ 0x20
	return string(b)
}

// --- Emitter ---

func emitGo(p page) string {
	var b strings.Builder
	fmt.Fprintf(&b, "// GENERATED by cmd/crudgen from %s.claude — DO NOT EDIT.\n\n", p.name)
	// No manual import block — goimports fills it in from the
	// referenced packages during writeGoFile's post-process step.
	b.WriteString(`package views

`)

	// Entry point
	fmt.Fprintf(&b, "func %s(w http.ResponseWriter, r *http.Request) {\n", p.handler)
	switch p.auth {
	case "user", "":
		b.WriteString("\tuserID := RequireAuth(w, r)\n\tif userID == 0 {\n\t\treturn\n\t}\n")
	case "admin":
		b.WriteString("\tuserID := RequireAuth(w, r)\n\tif userID == 0 {\n\t\treturn\n\t}\n")
		b.WriteString("\tif !auth.IsAdmin(userID) {\n\t\thttp.Error(w, \"Admin only\", http.StatusForbidden)\n\t\treturn\n\t}\n")
	}
	// Dispatch: POST handlers first (in declared order, most specific
	// first), then views. Each handler's predicates become a guard.
	for _, h := range p.handlers {
		guard := dispatchGuard(h.predicates)
		fmt.Fprintf(&b, "\tif %s {\n\t\t%s_handler_%s(w, r, userID)\n\t\treturn\n\t}\n",
			guard, p.name, h.name)
	}
	for _, v := range p.views {
		if strings.Contains(v.when, "method=GET") || v.when == "" {
			fmt.Fprintf(&b, "\t%s_view_%s(w, userID)\n\treturn\n", p.name, v.name)
			break
		}
	}
	b.WriteString("}\n\n")

	// Emit each view
	for _, v := range p.views {
		emitView(&b, p, v)
	}

	// Emit each handler
	for _, h := range p.handlers {
		emitHandler(&b, p, h)
	}

	// Self-register into the PageDef list so main.go never has to
	// touch registry.go for a new .claude-backed page. Skip if nav
	// is empty AND admin-only — that's a "no nav entry" admin page
	// and it stil registers, just doesn't appear in nav (same as
	// hardcoded admin-only entries today).
	emitRegistration(&b, p)

	return b.String()
}

func emitRegistration(b *strings.Builder, p page) {
	fmt.Fprintf(b, `
func init() {
	registerGeneratedPage(PageDef{
		Path:      %q,
		NavLabel:  %q,
		Title:     %q,
		Subtitle:  %q,
		Handler:   %s,
		AdminOnly: %t,
	})
}
`, p.path, p.nav, p.title, p.subtitle, p.handler, p.adminOnly)
}

func emitView(b *strings.Builder, p page, v view) {
	fmt.Fprintf(b, "func %s_view_%s(w http.ResponseWriter, userID int) {\n", p.name, v.name)
	b.WriteString("\tw.Header().Set(\"Content-Type\", \"text/html; charset=utf-8\")\n")
	fmt.Fprintf(b, "\tPageHeader(w, %q)\n", p.title)
	if p.subtitle != "" {
		fmt.Fprintf(b, "\tPageSubtitle(w, %q)\n", p.subtitle)
	}

	if v.preamble != nil {
		emitPreamble(b, v.preamble)
	}

	if v.table != nil {
		emitTable(b, v.table)
	}

	b.WriteString("\tPageFooter(w)\n}\n\n")
}

func emitPreamble(b *strings.Builder, pre *preamble) {
	for _, q := range pre.vars {
		fmt.Fprintf(b, "\tvar %s int\n", q.name)
		sql := sqlToGoParams(q.sql)
		paramList := ""
		if len(sql.params) > 0 {
			paramList = ", " + strings.Join(sql.params, ", ")
		}
		fmt.Fprintf(b, "\tDB.QueryRow(%s%s).Scan(&%s)\n", sqlLit(sql.text), paramList, q.name)
	}
	// Preamble text gets wrapped in <p>...</p> automatically; user
	// provides inline content only.
	wrapped := "<p>" + pre.text + "</p>"
	goFmt, args := substitutePlaceholders(wrapped, pre.vars)
	if len(args) == 0 {
		fmt.Fprintf(b, "\tfmt.Fprint(w, %s)\n", quoteHTML(goFmt))
	} else {
		fmt.Fprintf(b, "\tfmt.Fprintf(w, %s, %s)\n", quoteHTML(goFmt), strings.Join(args, ", "))
	}
}

func emitTable(b *strings.Builder, t *tableSpec) {
	sql := sqlToGoParams(t.query)
	paramList := ""
	if len(sql.params) > 0 {
		paramList = ", " + strings.Join(sql.params, ", ")
	}
	fmt.Fprintf(b, "\trows, err := DB.Query(%s%s)\n", sqlLit(sql.text), paramList)
	b.WriteString("\tif err != nil {\n\t\tfmt.Fprint(w, `<p>Failed to load.</p>`)\n\t\tPageFooter(w)\n\t\treturn\n\t}\n")
	b.WriteString("\tdefer rows.Close()\n")

	// Table header
	b.WriteString("\tfmt.Fprint(w, `<table><thead><tr>")
	for _, c := range t.columns {
		fmt.Fprintf(b, "<th>%s</th>", htmlEscapeInBacktick(c.header))
	}
	b.WriteString("</tr></thead><tbody>`)\n")

	// Declare scan variables based on SQL columns (parsed from SELECT).
	selectCols := parseSelectColumns(t.query)
	b.WriteString("\thasAny := false\n")
	b.WriteString("\tfor rows.Next() {\n")
	b.WriteString("\t\thasAny = true\n")
	for _, col := range selectCols {
		fmt.Fprintf(b, "\t\tvar %s %s\n", col.goName, col.goType)
	}
	var scanArgs []string
	for _, col := range selectCols {
		scanArgs = append(scanArgs, "&"+col.goName)
	}
	fmt.Fprintf(b, "\t\trows.Scan(%s)\n", strings.Join(scanArgs, ", "))
	b.WriteString("\t\tfmt.Fprint(w, `<tr>`)\n")
	for _, c := range t.columns {
		emitColumnCell(b, c)
	}
	b.WriteString("\t\tfmt.Fprint(w, `</tr>`)\n")
	b.WriteString("\t}\n")
	b.WriteString("\tfmt.Fprint(w, `</tbody></table>`)\n")
	if t.empty != "" {
		fmt.Fprintf(b, "\tif !hasAny {\n\t\tfmt.Fprint(w, `<p class=\"muted\">%s</p>`)\n\t}\n", t.empty)
	}
}

func emitColumnCell(b *strings.Builder, c column) {
	switch c.renderer {
	case "text":
		fieldName := c.args["_0"]
		goVar := goVarFromSQL(fieldName)
		if inferGoType(fieldName) == "int" {
			fmt.Fprintf(b, "\t\tfmt.Fprintf(w, `<td>%%d</td>`, %s)\n", goVar)
		} else {
			fmt.Fprintf(b, "\t\tfmt.Fprintf(w, `<td>%%s</td>`, html.EscapeString(%s))\n", goVar)
		}
	case "toggle_form":
		flagArg := c.args["_0"]
		post := c.args["post"]
		fieldName := c.args["field"]
		valueField := c.args["value"]
		fmt.Fprintf(b, "\t\tcheckedAttr_ := \"\"\n\t\tif %s {\n\t\t\tcheckedAttr_ = \" checked\"\n\t\t}\n", goVarFromSQL(flagArg))
		fmt.Fprintf(b, "\t\tfmt.Fprintf(w, `<td><form method=\"POST\" action=\"%s\" style=\"margin:0\">`+\n", post)
		fmt.Fprintf(b, "\t\t\t`<input type=\"hidden\" name=\"%s\" value=\"%%d\">`+\n", fieldName)
		// The %s here is part of the generated source — not a
		// format directive for this Fprint. WriteString sidesteps
		// go vet's printf-lint which otherwise flags Fprint with
		// a %-containing literal.
		b.WriteString("\t\t\t`<input type=\"checkbox\" onchange=\"this.form.submit()\"%s></form></td>`,\n")
		fmt.Fprintf(b, "\t\t\t%s, checkedAttr_)\n", goVarFromSQL(valueField))
	default:
		fmt.Fprintf(b, "\t\tfmt.Fprint(w, `<td>?renderer:%s?</td>`)\n", c.renderer)
	}
}

func dispatchGuard(preds []predicate) string {
	var parts []string
	for _, p := range preds {
		switch p.kind {
		case "method":
			parts = append(parts, fmt.Sprintf("r.Method == %q", p.value))
		case "has_param":
			parts = append(parts, fmt.Sprintf("r.URL.Query().Get(%q) != \"\"", p.param))
		case "param_eq":
			parts = append(parts, fmt.Sprintf("r.URL.Query().Get(%q) == %q", p.param, p.value))
		}
	}
	if len(parts) == 0 {
		return "true"
	}
	return strings.Join(parts, " && ")
}

// emitQueryParamExtraction auto-declares Go variables for any
// URL-query params named in the handler's when-predicates — e.g.
// `when: method=POST id label=1` emits `id := atoi(Query["id"])`
// so the update SQL's `WHERE id = ?` has a binding. Tracks which
// names were emitted so we don't double-declare fields.
func emitQueryParamExtraction(b *strings.Builder, h handler) map[string]bool {
	declared := map[string]bool{}
	for _, pred := range h.predicates {
		name := pred.param
		if name == "" || declared[name] {
			continue
		}
		declared[name] = true
		if pred.kind == "has_param" {
			fmt.Fprintf(b, "\t%sStr_ := r.URL.Query().Get(%q)\n", name, name)
			fmt.Fprintf(b, "\t%s, _ := strconv.Atoi(%sStr_)\n", name, name)
		}
		// param_eq doesn't need a Go binding (value is hardcoded
		// in the dispatcher guard).
	}
	return declared
}

func emitHandler(b *strings.Builder, p page, h handler) {
	fmt.Fprintf(b, "func %s_handler_%s(w http.ResponseWriter, r *http.Request, userID int) {\n", p.name, h.name)
	b.WriteString("\tr.ParseForm()\n")
	emitQueryParamExtraction(b, h)
	for _, f := range h.fields {
		switch f.goType {
		case "int":
			fmt.Fprintf(b, "\t%sStr := r.FormValue(%q)\n", f.name, f.name)
			fmt.Fprintf(b, "\t%s, _ := strconv.Atoi(%sStr)\n", f.name, f.name)
			if f.required {
				fmt.Fprintf(b, "\tif %s == 0 {\n\t\thttp.Error(w, \"Missing %s\", http.StatusBadRequest)\n\t\treturn\n\t}\n", f.name, f.name)
			}
		case "string":
			fmt.Fprintf(b, "\t%s := r.FormValue(%q)\n", f.name, f.name)
			if f.required {
				fmt.Fprintf(b, "\tif %s == \"\" {\n\t\thttp.Error(w, \"Missing %s\", http.StatusBadRequest)\n\t\treturn\n\t}\n", f.name, f.name)
			}
		}
	}

	emitAction(b, h.action)

	if h.redirect != "" {
		fmt.Fprintf(b, "\thttp.Redirect(w, r, %q, http.StatusSeeOther)\n", h.redirect)
	}
	b.WriteString("}\n\n")
}

func emitAction(b *strings.Builder, a action) {
	switch a.kind {
	case "toggle_row":
		table := a.attrs["table"]
		match := a.attrs["match"]
		// match is "user_id=$user, buddy_id=$buddy_id"
		pairs := splitArgs(match)
		var cols []string
		var vars []string
		for _, p := range pairs {
			p = strings.TrimSpace(p)
			k, v, _ := strings.Cut(p, "=")
			cols = append(cols, strings.TrimSpace(k))
			vars = append(vars, dollarVarToGo(strings.TrimSpace(v)))
		}
		where := ""
		for i, c := range cols {
			if i > 0 {
				where += " AND "
			}
			where += c + " = ?"
		}
		placeholders := strings.TrimRight(strings.Repeat("?, ", len(cols)), ", ")
		varsList := strings.Join(vars, ", ")
		fmt.Fprintf(b, "\tvar existing_ int\n\tDB.QueryRow(`SELECT COUNT(*) FROM %s WHERE %s`, %s).Scan(&existing_)\n",
			table, where, varsList)
		fmt.Fprintf(b, "\tif existing_ > 0 {\n\t\tDB.Exec(`DELETE FROM %s WHERE %s`, %s)\n",
			table, where, varsList)
		fmt.Fprintf(b, "\t} else {\n\t\tDB.Exec(`INSERT OR IGNORE INTO %s (%s) VALUES (%s)`, %s)\n\t}\n",
			table, strings.Join(cols, ", "), placeholders, varsList)
	case "update_row":
		emitUpdateRow(b, a)
	case "insert_row":
		emitInsertRow(b, a)
	default:
		fmt.Fprintf(b, "\t// unsupported action: %s\n", a.kind)
	}
}

// emitUpdateRow handles:
//
//	action: update_row
//	  table: games
//	  set:   label=$label
//	  where: id=$id
func emitUpdateRow(b *strings.Builder, a action) {
	table := a.attrs["table"]
	setPairs := parsePairs(a.attrs["set"])
	wherePairs := parsePairs(a.attrs["where"])

	var setCols []string
	var setVars []string
	for _, p := range setPairs {
		setCols = append(setCols, p.col+" = "+sqlValueExpr(p.value))
		if v := dollarArgFor(p.value); v != "" {
			setVars = append(setVars, v)
		}
	}
	var whereCols []string
	var whereVars []string
	for _, p := range wherePairs {
		whereCols = append(whereCols, p.col+" = ?")
		whereVars = append(whereVars, dollarVarToGo(p.value))
	}

	args := append([]string{}, setVars...)
	args = append(args, whereVars...)
	argsList := ""
	if len(args) > 0 {
		argsList = ", " + strings.Join(args, ", ")
	}
	fmt.Fprintf(b, "\tDB.Exec(`UPDATE %s SET %s WHERE %s`%s)\n",
		table, strings.Join(setCols, ", "), strings.Join(whereCols, " AND "), argsList)
}

// emitInsertRow handles:
//
//	action: insert_row
//	  table: games
//	  columns: game_type="lynrummy", player1_id=$user, created_at=now, ...
//
// Special value keywords: now → time.Now().Unix(); "lit" → bound
// string; $var → Go variable.
func emitInsertRow(b *strings.Builder, a action) {
	table := a.attrs["table"]
	pairs := parsePairs(a.attrs["columns"])

	var cols []string
	var placeholders []string
	var args []string
	for _, p := range pairs {
		cols = append(cols, p.col)
		placeholders = append(placeholders, "?")
		args = append(args, sqlArgExpr(p.value))
	}
	argsList := ""
	if len(args) > 0 {
		argsList = ", " + strings.Join(args, ", ")
	}
	fmt.Fprintf(b, "\t_, _ = DB.Exec(`INSERT INTO %s (%s) VALUES (%s)`%s)\n",
		table, strings.Join(cols, ", "), strings.Join(placeholders, ", "), argsList)
}

// parsePairs parses "col1=val1, col2=val2" into ordered (col, val) pairs.
type kvPair struct{ col, value string }

func parsePairs(s string) []kvPair {
	var out []kvPair
	for _, part := range splitArgs(s) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if eq := strings.Index(part, "="); eq > 0 {
			out = append(out, kvPair{
				col:   strings.TrimSpace(part[:eq]),
				value: strings.TrimSpace(part[eq+1:]),
			})
		}
	}
	return out
}

// sqlValueExpr renders an update `SET col = X` fragment where X
// is either a literal SQL expression (nullif, now) or a `?`
// placeholder. Returns just the `?` or the fragment (no binding).
func sqlValueExpr(v string) string {
	if strings.HasPrefix(v, "nullif(") {
		// nullif($x, "") → NULLIF(?, '')
		return `NULLIF(?, '')`
	}
	if v == "now" {
		return "?"
	}
	return "?"
}

// sqlArgExpr returns the Go expression for a DSL value used as a
// SQL bind arg. Handles literal strings, $var references, and
// special keywords like `now`.
func sqlArgExpr(v string) string {
	if v == "now" {
		return "time.Now().Unix()"
	}
	if strings.HasPrefix(v, "\"") && strings.HasSuffix(v, "\"") {
		return v // literal Go string
	}
	if strings.HasPrefix(v, "nullif(") {
		inner := strings.TrimSuffix(strings.TrimPrefix(v, "nullif("), ")")
		arg, _, _ := strings.Cut(inner, ",")
		return dollarVarToGo(strings.TrimSpace(arg))
	}
	return dollarVarToGo(v)
}

// dollarArgFor returns the Go expression to bind for `$var` values
// used inside nullif or similar expressions. Empty string if the
// value doesn't bind anything.
func dollarArgFor(v string) string {
	if strings.HasPrefix(v, "nullif(") {
		inner := strings.TrimSuffix(strings.TrimPrefix(v, "nullif("), ")")
		arg, _, _ := strings.Cut(inner, ",")
		return dollarVarToGo(strings.TrimSpace(arg))
	}
	return dollarVarToGo(v)
}

// --- SQL helpers ---

type sqlBinding struct {
	text   string   // SQL with ? placeholders
	params []string // Go expressions for each placeholder, in order
}

func sqlToGoParams(sql string) sqlBinding {
	// Translate $user, $<field> placeholders into ? with corresponding
	// Go variable args.
	out := sqlBinding{}
	var buf strings.Builder
	for i := 0; i < len(sql); i++ {
		if sql[i] == '$' {
			j := i + 1
			for j < len(sql) && (isAlnum(sql[j]) || sql[j] == '_') {
				j++
			}
			name := sql[i+1 : j]
			out.params = append(out.params, dollarVarToGoName(name))
			buf.WriteByte('?')
			i = j - 1
		} else {
			buf.WriteByte(sql[i])
		}
	}
	out.text = strings.TrimSpace(collapseWhitespace(buf.String()))
	return out
}

func dollarVarToGo(v string) string {
	if strings.HasPrefix(v, "$") {
		return dollarVarToGoName(v[1:])
	}
	return v
}

func dollarVarToGoName(name string) string {
	if name == "user" {
		return "userID"
	}
	return name
}

func isAlnum(b byte) bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func collapseWhitespace(s string) string {
	var out strings.Builder
	prevSpace := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\t' || c == '\n' || c == ' ' {
			if !prevSpace {
				out.WriteByte(' ')
				prevSpace = true
			}
		} else {
			out.WriteByte(c)
			prevSpace = false
		}
	}
	return out.String()
}

// parseSelectColumns extracts (name, go-type) for each SELECT column,
// naively. Handles "table.col AS alias" and "COUNT(*)" patterns we
// actually use. Extend as needed.
type selectCol struct {
	goName string
	goType string
}

func parseSelectColumns(sql string) []selectCol {
	u := strings.ToUpper(sql)
	si := strings.Index(u, "SELECT")
	if si < 0 {
		return nil
	}
	// Find FROM at paren-depth 0 (skip FROMs inside subqueries like
	// EXISTS(SELECT 1 FROM ...)).
	fi := -1
	depth := 0
	for i := si + 6; i < len(u); i++ {
		switch u[i] {
		case '(':
			depth++
		case ')':
			depth--
		}
		if depth == 0 && i+4 < len(u) && u[i:i+4] == "FROM" {
			// Must be a word boundary on both sides.
			if (i == 0 || !isAlnum(u[i-1])) && (i+4 == len(u) || !isAlnum(u[i+4])) {
				fi = i
				break
			}
		}
	}
	if fi < 0 {
		return nil
	}
	inner := sql[si+6 : fi]
	parts := splitArgs(inner)
	var out []selectCol
	for _, p := range parts {
		p = strings.TrimSpace(p)
		// Handle "expr AS alias"
		name := p
		if upper := strings.ToUpper(p); strings.Contains(upper, " AS ") {
			idx := strings.LastIndex(upper, " AS ")
			name = strings.TrimSpace(p[idx+4:])
		} else if strings.Contains(p, ".") {
			name = strings.TrimSpace(p[strings.LastIndex(p, ".")+1:])
		}
		goName := camel(name)
		goType := inferGoType(name)
		out = append(out, selectCol{goName: goName, goType: goType})
	}
	return out
}

func camel(s string) string {
	parts := strings.Split(s, "_")
	var buf strings.Builder
	for i, p := range parts {
		if p == "" {
			continue
		}
		if i == 0 {
			buf.WriteString(p)
		} else {
			buf.WriteByte(p[0] &^ 0x20)
			buf.WriteString(p[1:])
		}
	}
	return buf.String()
}

func inferGoType(colName string) string {
	lower := strings.ToLower(colName)
	switch {
	case lower == "id" || strings.HasSuffix(lower, "_id"):
		return "int"
	case strings.HasPrefix(lower, "is_") || strings.HasPrefix(lower, "has_"):
		return "bool"
	case lower == "count" || strings.HasSuffix(lower, "_count") || lower == "events":
		return "int"
	default:
		return "string"
	}
}

func goVarFromSQL(sqlField string) string {
	return camel(strings.TrimSpace(sqlField))
}

// --- Emit helpers ---

func sqlLit(s string) string {
	return fmt.Sprintf("`%s`", s)
}

func htmlEscapeInBacktick(s string) string {
	// Backticked Go strings can't contain backtick. For headers
	// that include ` we'd need to concat; we don't use them.
	return s
}

func quoteHTML(s string) string {
	// Emits s as a Go string literal in backtick form when safe,
	// double-quoted with standard escaping when backticks are present.
	if !strings.Contains(s, "`") {
		return "`" + s + "`"
	}
	return strconvQuote(s)
}

func strconvQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case '\n':
			b.WriteString("\\n")
		case '\t':
			b.WriteString("\\t")
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func substitutePlaceholders(template string, vars []namedQuery) (goFmt string, args []string) {
	goFmt = template
	for _, v := range vars {
		placeholder := "{" + v.name + "}"
		if strings.Contains(goFmt, placeholder) {
			goFmt = strings.Replace(goFmt, placeholder, "%d", 1)
			args = append(args, v.name)
		}
	}
	return
}
