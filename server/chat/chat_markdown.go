// Markdown rendering for chat. goldmark turns a message body into HTML;
// bluemonday then sanitizes it, so a message from one player is safe to
// drop into another player's browser (stored-XSS is a real risk here —
// each side renders the other's text). goldmark passes raw HTML through
// (WithUnsafe — needed so the upload handler can emit an <img> tag with
// width/height attrs, which it does so the browser can reserve correctly-
// proportioned space before the image decodes); bluemonday is the real
// safety net, with UGCPolicy stripping anything dangerous (scripts, event
// handlers, javascript:/data: URLs).
package chat

import (
	"bytes"
	"html/template"
	"regexp"

	"github.com/microcosm-cc/bluemonday"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer"
	gmhtml "github.com/yuin/goldmark/renderer/html"
	"github.com/yuin/goldmark/util"
)

// chatMarkdown renders with GFM (autolinks, strikethrough, tables) and
// hard wraps — in chat a single newline means a line break, not a space.
// quoteFenceRenderer (priority below the default 1000) overrides fenced-code
// rendering so a fenced block tagged `quote` becomes a styled quote instead
// of a code block.
var chatMarkdown = goldmark.New(
	goldmark.WithExtensions(extension.GFM),
	goldmark.WithRendererOptions(
		gmhtml.WithHardWraps(),
		gmhtml.WithUnsafe(), // raw HTML through; bluemonday sanitizes
		renderer.WithNodeRenderers(util.Prioritized(quoteFenceRenderer{}, 100)),
	),
)

// quoteFenceRenderer renders a fenced block tagged `quote` as a styled quote
// (verbatim text in <pre class="chat-quote">) and lets every other fenced
// block fall through to the standard <pre><code class="language-…"> output.
// Verbatim, like a code block: the quoted text's own markdown and MSG_ refs
// are shown literally (the <pre> keeps linkifyMsgRefs from touching them).
type quoteFenceRenderer struct{}

func (quoteFenceRenderer) RegisterFuncs(reg renderer.NodeRendererFuncRegisterer) {
	reg.Register(ast.KindFencedCodeBlock, renderFencedCodeBlock)
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

// chatSanitizer is the user-generated-content policy: standard formatting
// tags (incl. img), safe link schemes, nothing executable. Relative URLs
// are allowed so uploaded images (/chat/uploads/...) survive. External
// (fully-qualified) links open in a new tab with rel=noopener; MSG_ refs
// are relative #fragments added after sanitization, so they're unaffected.
var chatSanitizer = func() *bluemonday.Policy {
	p := bluemonday.UGCPolicy()
	p.AllowRelativeURLs(true)
	p.AddTargetBlankToFullyQualifiedLinks(true)
	// Keep the marker class on quote blocks (see quoteFenceRenderer) so the
	// CSS can style them; the value is fixed, so this opens no real surface.
	p.AllowAttrs("class").Matching(regexp.MustCompile(`^chat-quote$`)).OnElements("pre")
	return p
}()

// RenderChatMarkdown converts a raw message body to safe rendered HTML.
// On a parse error it falls back to escaped plain text rather than
// dropping the message.
func RenderChatMarkdown(src string) template.HTML {
	var buf bytes.Buffer
	if err := chatMarkdown.Convert([]byte(src), &buf); err != nil {
		return template.HTML(template.HTMLEscapeString(src))
	}
	safe := chatSanitizer.SanitizeBytes(buf.Bytes())
	return template.HTML(linkifyMsgRefs(string(safe)))
}
