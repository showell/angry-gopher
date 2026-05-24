package web

import (
	"fmt"
	"html"
	"net/http"
)

// RenderAPIKeyShown displays a freshly generated key once, with a copy
// warning and usage hint. backURL/backLabel point the "← back" link at
// whichever surface generated it (admin or the member's own settings).
func RenderAPIKeyShown(w http.ResponseWriter, id, key, backURL, backLabel string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 640px; }
h1 { color: #000080; font-size: 22px; }
nav a { color: #000080; }
.warn { color: #b00020; }
.box { background: #f4f4ec; border: 1px solid #ccc; border-radius: 6px; padding: 16px 20px; }
code.key { font-family: ui-monospace,Menlo,Consolas,monospace; font-size: 15px;
           background: #fff; border: 1px solid #ccc; padding: 8px 12px; border-radius: 4px;
           display: block; user-select: all; word-break: break-all; }
.muted { color: #888; font-size: 13px; }
</style>
</head><body>
<nav><a href="%s">← %s</a></nav>
<h1>API key for &ldquo;%s&rdquo;</h1>
<div class="box">
<p class="warn"><strong>Copy this for the bot.</strong></p>
<code class="key">%s</code>
<p class="muted">Read-only. The bot sends it as <code>Authorization: Bearer &lt;key&gt;</code>.
Hand it to the bot via the <code>GOPHER_API_KEY</code> env var, not in the prompt. Revoke anytime.</p>
</div>
</body></html>`, html.EscapeString(backURL), html.EscapeString(backLabel),
		html.EscapeString(GetUserName(id)), html.EscapeString(key))
}
