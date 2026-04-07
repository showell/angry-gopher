// Markdown-to-HTML rendering for message content.
// Uses goldmark (CommonMark-compliant) as the base parser, then
// post-processes to handle Zulip-specific conventions like inline
// image previews for uploaded files.

package main

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/yuin/goldmark"
)

var md = goldmark.New()

var imageExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true,
	".gif": true, ".webp": true, ".svg": true,
}

func renderMarkdown(source string) string {
	var buf bytes.Buffer
	if err := md.Convert([]byte(source), &buf); err != nil {
		return "<p>" + source + "</p>"
	}
	html := buf.String()

	// Zulip appends inline image previews for links to uploaded images.
	// Detect links to /user_uploads/ with image extensions and append
	// an <img> tag so Angry Cat's fix_images can process them.
	html = appendImagePreviews(html)

	return html
}

func appendImagePreviews(html string) string {
	// Look for links like: <a href="/user_uploads/1/photo.png">...</a>
	// and append a Zulip-style inline image preview after the paragraph.
	const marker = `href="/user_uploads/`
	if !strings.Contains(html, marker) {
		return html
	}

	var previews []string
	remaining := html
	for {
		idx := strings.Index(remaining, marker)
		if idx < 0 {
			break
		}
		// Extract the URL from href="..."
		start := idx + len(`href="`)
		end := strings.Index(remaining[start:], `"`)
		if end < 0 {
			break
		}
		href := remaining[start : start+end]

		// Check if it's an image by extension.
		dotIdx := strings.LastIndex(href, ".")
		if dotIdx >= 0 && imageExtensions[strings.ToLower(href[dotIdx:])] {
			preview := fmt.Sprintf(
				`<div class="message_inline_image">`+
					`<a href="%s"><img src="%s"></a>`+
					`</div>`,
				href, href,
			)
			previews = append(previews, preview)
		}

		remaining = remaining[start+end:]
	}

	if len(previews) > 0 {
		html += strings.Join(previews, "\n") + "\n"
	}
	return html
}
