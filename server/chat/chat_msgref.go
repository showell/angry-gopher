// Linkifies message references: a MSG_<6 hex> token in a message becomes
// a link to #msg-<hash>. Done as a post-pass over the already-sanitized
// HTML rather than a goldmark extension: goldmark splits text at the
// underscore in MSG_ (it's an emphasis delimiter), so "MSG_" and the hex
// land in separate text nodes, defeating both an inline parser and an AST
// transformer. We instead tokenize the rendered HTML into tags vs. text
// and rewrite only text outside <code>/<pre>/<a>, so a MSG_ inside a code
// span or an existing link is left alone. The injected anchor is a fixed
// safe shape (the hash is [0-9A-F]{6}), so running after sanitization is
// safe.
package chat

import (
	"regexp"
	"strings"
)

// msgRefRe matches a MSG_ reference token on word boundaries (so it won't
// fire inside a longer token like FOOMSG_ABC123 or MSG_ABC1234).
var msgRefRe = regexp.MustCompile(`\bMSG_([0-9A-F]{6})\b`)

// linkifyMsgRefs rewrites MSG_<hash> tokens in HTML text into reference
// links, skipping the contents of <code>, <pre>, and <a> elements.
func linkifyMsgRefs(htmlStr string) string {
	var out strings.Builder
	skip := 0 // nesting depth inside code/pre/a, where we don't rewrite
	i := 0
	for i < len(htmlStr) {
		if htmlStr[i] == '<' {
			end := strings.IndexByte(htmlStr[i:], '>')
			if end < 0 {
				out.WriteString(htmlStr[i:])
				break
			}
			tag := htmlStr[i : i+end+1]
			out.WriteString(tag)
			lower := strings.ToLower(tag)
			switch {
			case strings.HasPrefix(lower, "<code") || strings.HasPrefix(lower, "<pre") || strings.HasPrefix(lower, "<a "):
				skip++
			case strings.HasPrefix(lower, "</code") || strings.HasPrefix(lower, "</pre") || strings.HasPrefix(lower, "</a"):
				if skip > 0 {
					skip--
				}
			}
			i += end + 1
			continue
		}
		next := strings.IndexByte(htmlStr[i:], '<')
		var textTok string
		if next < 0 {
			textTok = htmlStr[i:]
			i = len(htmlStr)
		} else {
			textTok = htmlStr[i : i+next]
			i += next
		}
		if skip == 0 {
			textTok = msgRefRe.ReplaceAllString(textTok,
				`<a href="#msg-$1" class="msg-ref">MSG_$1</a>`)
		}
		out.WriteString(textTok)
	}
	return out.String()
}
