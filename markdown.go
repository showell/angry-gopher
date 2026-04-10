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
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer/html"
)

var md = goldmark.New(
	// WithUnsafe allows our pre-processed inline HTML (mentions,
	// channel links) to pass through without being stripped.
	goldmark.WithRendererOptions(html.WithUnsafe()),
	// GFM extensions: strikethrough (~~text~~), tables, etc.
	goldmark.WithExtensions(extension.GFM),
)

var imageExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true,
	".gif": true, ".webp": true, ".svg": true,
}

// Matches @**Name**, #**Channel**, #**Channel>Topic**, #**Channel>Topic@MsgID**
var mentionRe = regexp.MustCompile(`@\*\*([^*]+)\*\*`)
var channelLinkRe = regexp.MustCompile(`#\*\*([^*]+)\*\*`)

// GitHub linkifiers:
//   #123           → issue/PR link (single configured repo)
//   owner/repo#123 → explicit repo reference
//   abc1234def     → commit link (7+ hex chars, word boundary)
var issueRe = regexp.MustCompile(`(?:^|[\s(])#(\d+)\b`)
var explicitIssueRe = regexp.MustCompile(`([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)#(\d+)`)
var commitRe = regexp.MustCompile(`(?:^|[\s(])([0-9a-f]{7,40})\b`)

func renderMarkdown(source string) string {
	// Pre-process Zulip-specific syntax before goldmark runs.
	// These produce inline HTML that goldmark passes through.
	source = processMentions(source)
	source = processChannelLinks(source)
	source = processLinkifiers(source)

	var buf bytes.Buffer
	if err := md.Convert([]byte(source), &buf); err != nil {
		return "<p>" + source + "</p>"
	}
	html := buf.String()

	html = wrapCodeBlocks(html)
	html = appendImagePreviews(html)

	return html
}

// wrapCodeBlocks wraps <pre><code> blocks in a Zulip-style
// <div class="codehilite"> so Angry Cat's CSS and click handlers
// recognize them.
func wrapCodeBlocks(html string) string {
	html = strings.ReplaceAll(html, "<pre><code>", `<div class="codehilite"><pre><code>`)
	html = strings.ReplaceAll(html, `<pre><code class="`, `<div class="codehilite"><pre><code class="`)
	html = strings.ReplaceAll(html, "</code></pre>", "</code></pre></div>")
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

// processLinkifiers converts GitHub references to links:
//   #123          → link (if exactly one repo configured or prefix matches)
//   AG#123        → link (custom prefix)
//   owner/repo#123 → link (explicit)
//   abc1234       → commit link (7+ hex chars)
func processLinkifiers(source string) string {
	// Load configured repos.
	type repo struct {
		owner, name, prefix string
	}
	var repos []repo
	rows, err := DB.Query(`SELECT owner, name, prefix FROM github_repos`)
	if err != nil || rows == nil {
		return source
	}
	for rows.Next() {
		var r repo
		rows.Scan(&r.owner, &r.name, &r.prefix)
		repos = append(repos, r)
	}
	rows.Close()

	if len(repos) == 0 {
		return source
	}

	// Explicit: owner/repo#123
	source = explicitIssueRe.ReplaceAllStringFunc(source, func(match string) string {
		parts := explicitIssueRe.FindStringSubmatch(match)
		fullName, num := parts[1], parts[2]
		for _, r := range repos {
			if r.owner+"/"+r.name == fullName {
				return fmt.Sprintf(`[%s](https://github.com/%s/issues/%s)`, match, fullName, num)
			}
		}
		return match
	})

	// Prefix: AG#123 or bare #123
	for _, r := range repos {
		if r.prefix != "" {
			// Custom prefix: AG#123
			prefixRe := regexp.MustCompile(`(?:^|[\s(])` + regexp.QuoteMeta(r.prefix) + `#(\d+)\b`)
			source = prefixRe.ReplaceAllStringFunc(source, func(match string) string {
				parts := prefixRe.FindStringSubmatch(match)
				num := parts[1]
				leading := match[:len(match)-len(r.prefix)-1-len(num)]
				link := fmt.Sprintf(`[%s#%s](https://github.com/%s/%s/issues/%s)`,
					r.prefix, num, r.owner, r.name, num)
				return leading + link
			})
		}
	}

	// Bare #123 — only if exactly one repo configured.
	if len(repos) == 1 {
		r := repos[0]
		source = issueRe.ReplaceAllStringFunc(source, func(match string) string {
			parts := issueRe.FindStringSubmatch(match)
			num := parts[1]
			leading := match[:len(match)-1-len(num)]
			link := fmt.Sprintf(`[#%s](https://github.com/%s/%s/issues/%s)`,
				num, r.owner, r.name, num)
			return leading + link
		})
	}

	// Commit hashes: 7+ hex chars.
	if len(repos) == 1 {
		r := repos[0]
		source = commitRe.ReplaceAllStringFunc(source, func(match string) string {
			parts := commitRe.FindStringSubmatch(match)
			sha := parts[1]
			short := sha
			if len(short) > 7 {
				short = short[:7]
			}
			leading := match[:len(match)-len(sha)]
			link := fmt.Sprintf(`[%s](https://github.com/%s/%s/commit/%s)`,
				short, r.owner, r.name, sha)
			return leading + link
		})
	}

	return source
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
