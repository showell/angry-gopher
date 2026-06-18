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

// linkifyMsgRefs is the post-render HTML pass. It rewrites MSG_<hash> tokens
// in text into reference links (skipping the contents of <code>, <pre>, and
// <a>), and marks external links to open in a new tab — replacing the
// target/rel decoration bluemonday used to add now that it's gone. Both run
// in a single tokenizing walk over tags vs. text.
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
			lower := strings.ToLower(tag)
			if strings.HasPrefix(lower, "<a ") {
				tag = openExternalInNewTab(tag, lower)
			}
			out.WriteString(tag)
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

// openExternalInNewTab adds target="_blank" rel="noopener" to an <a> open tag
// whose href is fully qualified (has a scheme + authority, e.g. https://…).
// Internal links — the injected #msg- refs and relative /uploads/… paths —
// have no scheme and are left to open in place. rel="noopener" is mandatory
// alongside target="_blank" to block reverse-tabnabbing. lower is tag
// lowercased (same length, so offsets align) for case-insensitive scanning.
func openExternalInNewTab(tag, lower string) string {
	href, ok := attrValueAt(tag, lower, "href")
	if !ok || !isExternalHref(href) {
		return tag
	}
	return tag[:len(tag)-1] + ` target="_blank" rel="noopener">`
}

// attrValueAt returns the double-quoted value of attr in tag (goldmark always
// double-quotes). lower is tag lowercased so the attr name match is
// case-insensitive while the value is sliced from the original-case tag.
func attrValueAt(tag, lower, attr string) (string, bool) {
	k := strings.Index(lower, attr+`="`)
	if k < 0 {
		return "", false
	}
	start := k + len(attr) + 2
	q := strings.IndexByte(tag[start:], '"')
	if q < 0 {
		return "", false
	}
	return tag[start : start+q], true
}

// isExternalHref reports whether href begins with "scheme://" (a scheme that
// starts with a letter, then scheme chars, then "://"). That's an off-site
// link; relative URLs and #fragments return false.
func isExternalHref(href string) bool {
	p := strings.Index(href, "://")
	if p <= 0 {
		return false
	}
	c := href[0]
	if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
		return false
	}
	for i := 1; i < p; i++ {
		c = href[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}
