// Markdown-to-HTML rendering for message content.
// Uses goldmark (CommonMark-compliant) as the base parser, with
// pre-processing for Zulip-specific syntax (@-mentions, channel/topic
// links) and post-processing for inline image previews.

package main

import (
	"bytes"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/renderer/html"
)

// WithUnsafe allows our pre-processed inline HTML (mentions, channel
// links) to pass through goldmark without being stripped.
var md = goldmark.New(
	goldmark.WithRendererOptions(html.WithUnsafe()),
)

var imageExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true,
	".gif": true, ".webp": true, ".svg": true,
}

// Matches @**Name**, #**Channel**, #**Channel>Topic**, #**Channel>Topic@MsgID**
var mentionRe = regexp.MustCompile(`@\*\*([^*]+)\*\*`)
var channelLinkRe = regexp.MustCompile(`#\*\*([^*]+)\*\*`)

func renderMarkdown(source string) string {
	// Pre-process Zulip-specific syntax before goldmark runs.
	// These produce inline HTML that goldmark passes through.
	source = processMentions(source)
	source = processChannelLinks(source)

	var buf bytes.Buffer
	if err := md.Convert([]byte(source), &buf); err != nil {
		return "<p>" + source + "</p>"
	}
	html := buf.String()

	html = appendImagePreviews(html)

	return html
}

// processMentions converts @**Name** to a Zulip-style user mention span.
func processMentions(source string) string {
	return mentionRe.ReplaceAllStringFunc(source, func(match string) string {
		name := mentionRe.FindStringSubmatch(match)[1]

		var userID int
		err := DB.QueryRow(`SELECT id FROM users WHERE full_name = ?`, name).Scan(&userID)
		if err != nil {
			// Not a known user — leave as-is for goldmark to render as bold.
			return match
		}

		return fmt.Sprintf(
			`<span class="user-mention" data-user-id="%d">@%s</span>`,
			userID, name,
		)
	})
}

// processChannelLinks converts #**...** to Zulip-style narrow links.
// Supported formats:
//
//	#**Channel**             → channel link
//	#**Channel>Topic**       → topic link
//	#**Channel>Topic@MsgID** → message link
func processChannelLinks(source string) string {
	return channelLinkRe.ReplaceAllStringFunc(source, func(match string) string {
		inner := channelLinkRe.FindStringSubmatch(match)[1]

		// Parse the inner text: Channel, Channel>Topic, or Channel>Topic@MsgID
		channelName := inner
		topicName := ""
		messageID := ""

		if idx := strings.Index(inner, ">"); idx >= 0 {
			channelName = inner[:idx]
			rest := inner[idx+1:]
			if atIdx := strings.Index(rest, "@"); atIdx >= 0 {
				topicName = rest[:atIdx]
				messageID = rest[atIdx+1:]
			} else {
				topicName = rest
			}
		}

		// Look up the channel ID.
		var channelID int
		err := DB.QueryRow(`SELECT channel_id FROM channels WHERE name = ?`, channelName).Scan(&channelID)
		if err != nil {
			return match
		}

		// Build the narrow URL.
		slug := fmt.Sprintf("%d-%s", channelID, url.PathEscape(channelName))
		href := fmt.Sprintf("/#narrow/channel/%s", slug)
		display := channelName

		if topicName != "" {
			href += fmt.Sprintf("/topic/%s", url.PathEscape(topicName))
			display += " > " + topicName
		}
		if messageID != "" {
			href += fmt.Sprintf("/near/%s", messageID)
			display += " @ " + messageID
		}

		return fmt.Sprintf(`<a href="%s">#%s</a>`, href, display)
	})
}

func appendImagePreviews(html string) string {
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
		start := idx + len(`href="`)
		end := strings.Index(remaining[start:], `"`)
		if end < 0 {
			break
		}
		href := remaining[start : start+end]

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
