// Markdown rendering for chat. goldmark turns a message body into HTML;
// bluemonday then sanitizes it, so a message from one player is safe to
// drop into another player's browser (stored-XSS is a real risk here —
// each side renders the other's text). goldmark already declines to emit
// raw HTML; bluemonday is the belt-and-suspenders pass that also strips
// dangerous link schemes (javascript:, data:) from any links.
package views

import (
	"bytes"
	"html/template"

	"github.com/microcosm-cc/bluemonday"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	gmhtml "github.com/yuin/goldmark/renderer/html"
)

// chatMarkdown renders with GFM (autolinks, strikethrough, tables) and
// hard wraps — in chat a single newline means a line break, not a space.
var chatMarkdown = goldmark.New(
	goldmark.WithExtensions(extension.GFM),
	goldmark.WithRendererOptions(gmhtml.WithHardWraps()),
)

// chatSanitizer is the user-generated-content policy: standard formatting
// tags, safe link schemes, nothing executable.
var chatSanitizer = bluemonday.UGCPolicy()

// RenderChatMarkdown converts a raw message body to safe rendered HTML.
// On a parse error it falls back to escaped plain text rather than
// dropping the message.
func RenderChatMarkdown(src string) template.HTML {
	var buf bytes.Buffer
	if err := chatMarkdown.Convert([]byte(src), &buf); err != nil {
		return template.HTML(template.HTMLEscapeString(src))
	}
	return template.HTML(chatSanitizer.SanitizeBytes(buf.Bytes()))
}
