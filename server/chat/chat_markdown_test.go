package chat

import (
	"strings"
	"testing"
)

// TestRenderChatMarkdownXSS pins the escape-but-<img> policy: the only raw
// HTML that survives rendering is a same-origin <img> rebuilt from an
// attribute allowlist; everything else is escaped to visible literal text.
func TestRenderChatMarkdownXSS(t *testing.T) {
	cases := []struct {
		name   string
		src    string
		want   []string // substrings that MUST appear
		reject []string // substrings that must NOT appear
	}{
		{
			name:   "script tag escaped to text",
			src:    "<script>alert(1)</script>",
			want:   []string{"&lt;script&gt;"},
			reject: []string{"<script>"},
		},
		{
			name:   "local img keeps allowlisted attrs only",
			src:    `<img src="/chat/c/1_2/x/uploads/a.png" alt="pic" width="10" height="20" onerror="alert(1)" onclick="x">`,
			want:   []string{`<img src="/chat/c/1_2/x/uploads/a.png" alt="pic" width="10" height="20">`},
			reject: []string{"onerror", "onclick", "alert"},
		},
		{
			name:   "img javascript src is not local, escaped to inert text",
			src:    `<img src="javascript:alert(1)">`,
			want:   []string{"&lt;img"},
			reject: []string{"<img", `src="javascript:`},
		},
		{
			name:   "protocol-relative img src rejected (offsite)",
			src:    `<img src="//evil.com/x.png">`,
			reject: []string{"<img"},
		},
		{
			name:   "backslash-escape img src rejected (offsite)",
			src:    `<img src="/\evil.com/x.png">`,
			reject: []string{"<img"},
		},
		{
			name:   "absolute https img src rejected (offsite)",
			src:    `<img src="https://evil.com/x.png">`,
			reject: []string{"<img"},
		},
		{
			// goldmark refuses to parse the malformed tag as HTML and escapes
			// the whole line — an extra safety layer below escape-but-<img>.
			name:   "malformed img with unquoted injection yields no live tag",
			src:    `<img src="/uploads/a.png" width=1onerror=alert(1)>`,
			want:   []string{"&lt;img"},
			reject: []string{"<img"},
		},
		{
			name:   "img followed by text on next line keeps both",
			src:    "<img src=\"/uploads/a.png\">\nwowww",
			want:   []string{`<img src="/uploads/a.png">`, "wowww"},
		},
		{
			name:   "raw anchor with javascript href escaped to text",
			src:    `<a href="javascript:alert(1)">click</a>`,
			want:   []string{"&lt;a", "&lt;/a&gt;"},
			reject: []string{"<a href=\"javascript:"},
		},
		{
			name:   "markdown link with javascript scheme drops href",
			src:    `[click](javascript:alert(1))`,
			reject: []string{"javascript:alert"},
		},
		{
			name:   "literal placeholders are shown, not dropped",
			src:    "use <sid> and <conv> in the path",
			want:   []string{"&lt;sid&gt;", "&lt;conv&gt;"},
		},
		{
			name:   "img src single-quoted is accepted",
			src:    `<img src='/uploads/a.png' alt='hi'>`,
			want:   []string{`<img src="/uploads/a.png" alt="hi">`},
		},
		{
			name:   "angle bracket in alt is escaped in output",
			src:    `<img src="/uploads/a.png" alt="a<b">`,
			want:   []string{`alt="a&lt;b"`},
			reject: []string{`alt="a<b"`},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := string(RenderChatMarkdown(tc.src))
			for _, w := range tc.want {
				if !strings.Contains(out, w) {
					t.Errorf("output missing %q\n  src:  %q\n  html: %q", w, tc.src, out)
				}
			}
			for _, r := range tc.reject {
				if strings.Contains(out, r) {
					t.Errorf("output should not contain %q\n  src:  %q\n  html: %q", r, tc.src, out)
				}
			}
		})
	}
}
