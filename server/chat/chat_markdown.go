// Markdown rendering for chat. goldmark turns a message body into HTML, and
// that HTML is dropped straight into the other player's browser — so stored
// XSS is a real risk (each side renders the other's text). We close that
// without a sanitizer pass by NOT enabling goldmark's WithUnsafe: goldmark
// then escapes dangerous link/image URLs itself (javascript:, vbscript:,
// non-image data:, file:) and would drop raw HTML entirely. We override the
// raw-HTML handling to escape it to literal text — EXCEPT a locked <img>,
// which our upload mechanism emits (with width/height so the browser can
// reserve correctly-proportioned space before decode). Users have no reason
// to type any other HTML, and bluemonday used to *silently drop* literal
// placeholders like <sid>/<conv> that people typed as text; escaping shows
// them instead. The <img> we re-admit is rebuilt from an attribute allowlist
// (src/alt/title/width/height), so no event handlers or scripts survive.
package chat

import (
	"bytes"
	"html/template"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer"
	gmhtml "github.com/yuin/goldmark/renderer/html"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// chatMarkdown renders with GFM (autolinks, strikethrough, tables) and
// hard wraps — in chat a single newline means a line break, not a space.
// WithUnsafe is deliberately OFF: goldmark then filters dangerous URLs and
// our chatNodeRenderer (priority below the default 1000) takes over fenced
// code (the `quote` tag) and raw HTML (escape-but-<img>).
var chatMarkdown = goldmark.New(
	goldmark.WithExtensions(extension.GFM),
	goldmark.WithRendererOptions(
		gmhtml.WithHardWraps(),
		renderer.WithNodeRenderers(util.Prioritized(chatNodeRenderer{}, 100)),
	),
)

// chatNodeRenderer overrides three node kinds:
//   - FencedCodeBlock: a block tagged `quote` becomes a styled quote; every
//     other fence falls through to the standard <pre><code> output.
//   - RawHTML / HTMLBlock: user-typed HTML is escaped to literal text, except
//     a single <img> tag, which is rebuilt from a fixed attribute allowlist.
type chatNodeRenderer struct{}

func (chatNodeRenderer) RegisterFuncs(reg renderer.NodeRendererFuncRegisterer) {
	reg.Register(ast.KindFencedCodeBlock, renderFencedCodeBlock)
	reg.Register(ast.KindRawHTML, renderRawHTML)
	reg.Register(ast.KindHTMLBlock, renderHTMLBlock)
}

func renderFencedCodeBlock(w util.BufWriter, source []byte, node ast.Node, entering bool) (ast.WalkStatus, error) {
	n := node.(*ast.FencedCodeBlock)
	lang := n.Language(source)
	if string(lang) == "quote" {
		if entering {
			w.WriteString(`<pre class="chat-quote">`)
			writeCodeLines(w, source, n)
		} else {
			w.WriteString("</pre>\n")
		}
		return ast.WalkContinue, nil
	}
	// Mirror goldmark's default fenced-code rendering for every other block.
	if entering {
		w.WriteString("<pre><code")
		if lang != nil {
			w.WriteString(` class="language-`)
			gmhtml.DefaultWriter.Write(w, lang)
			w.WriteString(`"`)
		}
		w.WriteByte('>')
		writeCodeLines(w, source, n)
	} else {
		w.WriteString("</code></pre>\n")
	}
	return ast.WalkContinue, nil
}

func writeCodeLines(w util.BufWriter, source []byte, n ast.Node) {
	lines := n.Lines()
	for i := 0; i < lines.Len(); i++ {
		line := lines.At(i)
		gmhtml.DefaultWriter.RawWrite(w, line.Value(source))
	}
}

// renderRawHTML handles inline raw HTML (e.g. an <img> pasted mid-line).
func renderRawHTML(w util.BufWriter, source []byte, node ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkSkipChildren, nil
	}
	n := node.(*ast.RawHTML)
	var raw []byte
	for i := 0; i < n.Segments.Len(); i++ {
		seg := n.Segments.At(i)
		raw = append(raw, seg.Value(source)...)
	}
	writeRawHTML(w, raw)
	return ast.WalkSkipChildren, nil
}

// renderHTMLBlock handles block-level raw HTML (the upload <img> lands here).
func renderHTMLBlock(w util.BufWriter, source []byte, node ast.Node, entering bool) (ast.WalkStatus, error) {
	if !entering {
		return ast.WalkContinue, nil
	}
	n := node.(*ast.HTMLBlock)
	var raw []byte
	lines := n.Lines()
	for i := 0; i < lines.Len(); i++ {
		line := lines.At(i)
		raw = append(raw, line.Value(source)...)
	}
	if n.HasClosure() {
		raw = append(raw, n.ClosureLine.Value(source)...)
	}
	writeRawHTML(w, raw)
	return ast.WalkContinue, nil
}

// writeRawHTML re-admits a single <img> tag (rebuilt from an attribute
// allowlist) and HTML-escapes anything else to literal text.
// writeRawHTML emits a chunk of user-typed raw HTML: each recognized <img>
// tag is rebuilt from its allowlisted attributes, and everything else (other
// tags, surrounding text, the newline after an image) is HTML-escaped to
// literal text. Scanning rather than treating the whole chunk as one tag
// matters because goldmark folds an <img> and the text on the next line into
// a single HTMLBlock (e.g. "<img …>\nwowww") — we must keep the image AND
// show the text.
func writeRawHTML(w util.BufWriter, raw []byte) {
	last := 0
	for i := 0; i < len(raw); {
		if raw[i] != '<' {
			i++
			continue
		}
		img, end, ok := safeImgAt(raw, i)
		if !ok {
			i++
			continue
		}
		w.Write(util.EscapeHTML(raw[last:i]))
		w.WriteString(img)
		i, last = end, end
	}
	w.Write(util.EscapeHTML(raw[last:]))
}

// imgAttrAllowlist is the only attributes a re-admitted <img> may carry, in
// emit order. width/height must be digits; the rest are HTML-escaped values.
var imgAttrAllowlist = []string{"src", "alt", "title", "width", "height"}

// safeImgAt tries to parse a single <img …> tag beginning at raw[start]. On
// success it returns the rebuilt locked tag and the index just past the
// closing '>'. Only same-origin srcs (see isLocalImgURL) are admitted; a tag
// with a missing/foreign src returns ok=false so the caller escapes it to
// visible text rather than silently dropping it.
func safeImgAt(raw []byte, start int) (string, int, bool) {
	attrs, end, ok := parseImgTagAt(raw, start)
	if !ok || !isLocalImgURL(strings.TrimSpace(attrs["src"])) {
		return "", 0, false
	}
	var b strings.Builder
	b.WriteString("<img")
	for _, name := range imgAttrAllowlist {
		v, present := attrs[name]
		if !present {
			continue
		}
		if (name == "width" || name == "height") && !isAllDigits(v) {
			continue
		}
		b.WriteByte(' ')
		b.WriteString(name)
		b.WriteString(`="`)
		b.Write(util.EscapeHTML([]byte(v)))
		b.WriteByte('"')
	}
	b.WriteByte('>')
	return b.String(), end, true
}

// parseImgTagAt parses one HTML <img> tag starting at s[start], returning its
// lowercased attributes and the index just past the closing '>'. Quotes are
// respected when scanning, so an attribute value may itself contain '>'. ok
// is false if s[start] doesn't open a well-formed <img> tag.
func parseImgTagAt(s []byte, start int) (map[string]string, int, bool) {
	if start+4 >= len(s) || s[start] != '<' || !bytes.EqualFold(s[start+1:start+4], []byte("img")) {
		return nil, 0, false
	}
	if c := s[start+4]; !isSpace(c) && c != '>' && c != '/' {
		return nil, 0, false // e.g. <imgx ...>
	}
	attrs := map[string]string{}
	i := start + 4
	for i < len(s) {
		c := s[i]
		switch {
		case isSpace(c) || c == '/':
			i++
		case c == '>':
			return attrs, i + 1, true
		default:
			nameStart := i
			for i < len(s) && isAttrNameChar(s[i]) {
				i++
			}
			if i == nameStart {
				return nil, 0, false // unexpected character
			}
			name := strings.ToLower(string(s[nameStart:i]))
			for i < len(s) && isSpace(s[i]) {
				i++
			}
			if i < len(s) && s[i] == '=' {
				i++
				for i < len(s) && isSpace(s[i]) {
					i++
				}
				if i >= len(s) {
					return nil, 0, false
				}
				if q := s[i]; q == '"' || q == '\'' {
					i++
					valStart := i
					for i < len(s) && s[i] != q {
						i++
					}
					if i >= len(s) {
						return nil, 0, false // unterminated value
					}
					attrs[name] = string(s[valStart:i])
					i++ // past closing quote
				} else {
					valStart := i
					for i < len(s) && !isSpace(s[i]) && s[i] != '>' {
						i++
					}
					attrs[name] = string(s[valStart:i])
				}
			} else {
				attrs[name] = "" // bare attribute
			}
		}
	}
	return nil, 0, false // no closing '>'
}

// isLocalImgURL accepts only same-origin, root-relative image URLs — the
// shape our upload mechanism emits (/chat/c/<conv>/<sid>/uploads/… and
// /channel/<name>/<topic>/uploads/…). A leading "/" resolves against the
// serving host (localhost:9000 in dev, lynrummy.com in prod) with no
// hostname hardcoded, so the same transcript renders correctly on both.
// "//host" and "/\host" are protocol-relative escapes to another origin and
// are rejected; so are absolute (scheme://) and javascript:/data: URLs,
// which simply don't start with a single "/". Tighter than a scheme
// blocklist: an offsite image can leak the viewer's IP / referrer or be a
// tracking pixel even when its scheme is "safe".
func isLocalImgURL(src string) bool {
	return len(src) >= 2 && src[0] == '/' && src[1] != '/' && src[1] != '\\'
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

func isAttrNameChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == ':'
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// ChatMarkdownAST parses src with the EXACT parser RenderChatMarkdown
// uses and returns the document root. Exposed so offline tooling — the
// markdown feature census and the zig-port gold tests — can walk the real
// AST goldmark produces instead of re-implementing the config (a mimic).
// Server code never calls this; rendering goes through RenderChatMarkdown.
func ChatMarkdownAST(src string) ast.Node {
	return chatMarkdown.Parser().Parse(text.NewReader([]byte(src)))
}

// RenderChatMarkdown converts a raw message body to safe rendered HTML.
// On a parse error it falls back to escaped plain text rather than
// dropping the message.
func RenderChatMarkdown(src string) template.HTML {
	var buf bytes.Buffer
	if err := chatMarkdown.Convert([]byte(src), &buf); err != nil {
		return template.HTML(template.HTMLEscapeString(src))
	}
	return template.HTML(linkifyMsgRefs(buf.String()))
}
