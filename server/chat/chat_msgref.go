// Linkifies message references: a MSG_<session-id>_<n> token in a
// message becomes a link to #msg-<id>. Done as a post-pass over the
// already-sanitized HTML rather than a goldmark extension: goldmark
// splits text at the underscore in MSG_ (it's an emphasis delimiter),
// so "MSG_" and the rest land in separate text nodes, defeating both
// an inline parser and an AST transformer. We instead tokenize the
// rendered HTML into tags vs. text and rewrite only text outside
// <code>/<pre>/<a>, so a MSG_ inside a code span or an existing link
// is left alone. The injected anchor is a fixed safe shape (slug +
// digits, all URL-safe), so running after sanitization is safe.
package chat

import (
	"regexp"
	"strings"
)

// msgRefRe matches a MSG_ reference token on word boundaries (so it won't
// fire inside a longer token). The id has shape <session-slug>_<n>,
// where session-slug is date-prefixed alphanumeric-with-hyphens (no
// underscores; that's the parsing constraint) and n is 1+ digits.
var msgRefRe = regexp.MustCompile(`\bMSG_([A-Za-z0-9-]+_[0-9]+)\b`)

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
