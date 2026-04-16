package views

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"

	"angry-gopher/dm"
)

// HandleDM serves GET /gopher/dm (conversation list or message view)
// and POST /gopher/dm (send a message).
func HandleDM(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleDMSend(w, r, userID)
		return
	}

	userIDParam := r.URL.Query().Get("user_id")
	if userIDParam != "" {
		otherID, _ := strconv.Atoi(userIDParam)
		if otherID != 0 {
			renderDMConversation(w, userID, otherID)
			return
		}
	}

	renderDMList(w, userID)
}

func renderDMList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, "Direct Messages", "claude")
	PageSubtitle(w, "Private 1:1 conversations.")

	// All users (for "New conversation" links).
	rows, err := DB.Query(`SELECT id, full_name FROM users WHERE id != ? ORDER BY full_name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load users.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	type userInfo struct {
		id       int
		name     string
		hasDMs   bool
		msgCount int
	}
	var users []userInfo
	for rows.Next() {
		var u userInfo
		rows.Scan(&u.id, &u.name)
		users = append(users, u)
	}

	// Check which users have existing conversations.
	for i := range users {
		lo, hi := userID, users[i].id
		if lo > hi {
			lo, hi = hi, lo
		}
		DB.QueryRow(`
			SELECT COUNT(*) FROM dm_messages dm
			JOIN dm_conversations dc ON dm.conversation_id = dc.id
			WHERE dc.user_id_1 = ? AND dc.user_id_2 = ?`,
			lo, hi).Scan(&users[i].msgCount)
		users[i].hasDMs = users[i].msgCount > 0
	}

	// Active conversations first.
	fmt.Fprint(w, `<h2>Conversations</h2>`)
	hasConvos := false
	fmt.Fprint(w, `<table><thead><tr><th>User</th><th>Messages</th></tr></thead><tbody>`)
	for _, u := range users {
		if !u.hasDMs {
			continue
		}
		hasConvos = true
		fmt.Fprintf(w, `<tr><td><a href="/gopher/dm?user_id=%d">%s</a> (%s)</td><td>%d</td></tr>`,
			u.id, html.EscapeString(u.name), UserLink(u.id, "profile"), u.msgCount)
	}
	fmt.Fprint(w, `</tbody></table>`)
	if !hasConvos {
		fmt.Fprint(w, `<p class="muted">No conversations yet.</p>`)
	}

	// All users for starting new conversations.
	fmt.Fprint(w, `<h2>Start a conversation</h2>`)
	fmt.Fprint(w, `<table><thead><tr><th>User</th></tr></thead><tbody>`)
	for _, u := range users {
		if u.hasDMs {
			continue
		}
		fmt.Fprintf(w, `<tr><td><a href="/gopher/dm?user_id=%d">%s</a></td></tr>`,
			u.id, html.EscapeString(u.name))
	}
	fmt.Fprint(w, `</tbody></table>`)

	PageFooter(w)
}

func renderDMConversation(w http.ResponseWriter, userID, otherID int) {
	var otherName string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, otherID).Scan(&otherName)
	if otherName == "" {
		http.Error(w, "Unknown user", http.StatusNotFound)
		return
	}

	lo, hi := userID, otherID
	if lo > hi {
		lo, hi = hi, lo
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeaderArea(w, fmt.Sprintf("DM with %s", otherName), "claude")

	fmt.Fprint(w, `<a class="back" href="/gopher/dm">&larr; Back to conversations</a>`)

	// Two-column split: thread on the left, compose on the right
	// (sticky). Collapses to one column under 900px.
	fmt.Fprint(w, `<style>
body { max-width: 1200px !important; }
.dm-split { display:grid; grid-template-columns: 1fr 420px; gap:24px; margin-top:12px; align-items:start; }
.dm-thread { min-width:0; }
.dm-compose { position:sticky; top:12px; background:#fcfcf8; border:1px solid #ccc;
              border-radius:4px; padding:12px; }
.dm-compose h3 { margin:0 0 8px; font-size:14px; color:#000080; }
@media (max-width: 900px) { .dm-split { grid-template-columns: 1fr; } .dm-compose { position:static; } }
</style>
<div class="dm-split">
<div class="dm-thread">`)

	// Messages.
	rows, err := DB.Query(`
		SELECT dm.id, dm.sender_id, u.full_name, mc.html, dm.timestamp
		FROM dm_messages dm
		JOIN dm_conversations dc ON dm.conversation_id = dc.id
		JOIN message_content mc ON dm.content_id = mc.content_id
		JOIN users u ON dm.sender_id = u.id
		WHERE dc.user_id_1 = ? AND dc.user_id_2 = ?
		ORDER BY dm.id ASC`,
		lo, hi)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load messages.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	msgCount := 0
	for rows.Next() {
		var senderID, msgID int
		var senderName, content string
		var timestamp int64
		// NOTE: intentionally selecting id here too; see query change below
		rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp)

		t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
		// Reply-marker parse: if the rendered content begins with
		// "↳ #N" (from the reply link), extract into a chip.
		replyChip := ""
		replyTo := extractReplyTo(content)
		if replyTo > 0 {
			replyChip = fmt.Sprintf(
				`<div style="font-size:12px;color:#555;margin-bottom:4px;">↳ in reply to <a href="#msg-%d">msg %d</a></div>`,
				replyTo, replyTo,
			)
			content = stripReplyMarker(content)
		}
		fmt.Fprintf(w, `<div id="msg-%d" style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> <span class="muted">msg %d · %s</span>
<a href="#" class="dm-reply-link" data-msgid="%d" style="margin-left:8px;font-size:12px;color:#000080;">↩ reply</a>
%s<div class="msg-content">%s</div>
</div>`,
			msgID, UserLink(senderID, senderName), msgID, html.EscapeString(t), msgID, replyChip, content)
		msgCount++
	}

	if msgCount == 0 {
		fmt.Fprint(w, `<p class="muted">No messages yet. Send the first one!</p>`)
	}

	// Compose form. Textarea is deliberately large (Steve's feedback
	// 2026-04-15: prior size was ~1/5 what he wanted). AJAX Send keeps
	// scroll at the bottom of long threads instead of a full page
	// reload that forces re-scrolling.
	fmt.Fprintf(w, `
<div id="dm-end"></div>
</div><!-- /dm-thread -->
<div class="dm-compose"><h3>Reply</h3>
<form id="dm-form" method="POST" action="/gopher/dm" style="margin-top:8px;">
<input type="hidden" name="to" value="%d">
<textarea name="content" placeholder="Message %s..." required
  style="width:100%%;min-height:200px;font-size:15px;padding:10px;box-sizing:border-box;"
  rows="12"></textarea>
<div style="margin-top:8px;"><button type="submit">Send</button>
<span id="dm-status" class="muted" style="margin-left:12px;"></span>
<span style="float:right;">
<a href="/gopher/claude-issues" style="background:#ffe0e8;padding:2px 8px;border-radius:3px;font-weight:bold;font-size:13px;text-decoration:none;">🗂️ Issues</a>
<a href="/gopher/wiki/" style="background:#f4f4f0;padding:2px 8px;border-radius:3px;font-weight:bold;font-size:13px;text-decoration:none;margin-left:4px;">📚 Wiki</a>
</span>
</div>
</form>
<script>
(function(){
  var form = document.getElementById('dm-form');
  var status = document.getElementById('dm-status');
  var end = document.getElementById('dm-end');
  end.scrollIntoView();
  form.addEventListener('submit', function(e){
    e.preventDefault();
    var ta = form.querySelector('textarea[name=content]');
    var body = ta.value.trim();
    if (!body) return;
    status.textContent = 'Sending…';
    var fd = new URLSearchParams(new FormData(form)).toString();
    fetch('/gopher/dm?ajax=1', {
      method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body: fd
    })
      .then(function(r){ return r.ok ? r.json() : Promise.reject(r.status); })
      .then(function(m){
        var div = document.createElement('div');
        div.style.cssText = 'margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc';
        div.innerHTML = '<b>'+escapeHtml(m.sender_name)+'</b> <span class="muted">'+escapeHtml(m.timestamp)+'</span><div class="msg-content">'+escapeHtml(m.content).replace(/\n/g,'<br>')+'</div>';
        end.parentNode.insertBefore(div, end);
        ta.value = '';
        status.textContent = 'Sent.';
        setTimeout(function(){ status.textContent=''; }, 1500);
        end.scrollIntoView({behavior:'smooth'});
        ta.focus();
      })
      .catch(function(err){ status.textContent = 'Failed ('+err+')'; });
  });
  function escapeHtml(s){ return String(s).replace(/[&<>"']/g, function(c){
    return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]; }); }

  // Reply links: clicking "↩ reply" on a message prepends a marker
  // (↳ #N) to the compose textarea and focuses it.
  document.addEventListener('click', function(e){
    var el = e.target.closest('.dm-reply-link');
    if (!el) return;
    e.preventDefault();
    var mid = el.getAttribute('data-msgid');
    var ta = form.querySelector('textarea[name=content]');
    var marker = '↳ #'+mid+'\n\n';
    ta.value = marker + (ta.value.replace(/^↳ #\d+\n\n/, ''));
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  });

  // Live-append incoming DMs when the current page is the matching conversation.
  // Matches /gopher/dm?user_id=N against the event URL (the sender's user_id).
  if (window.EventSource) {
    var myUrl = location.pathname + location.search;
    var es = new EventSource('/gopher/sse/claude-activity');
    es.addEventListener('activity', function(ev) {
      try {
        var d = JSON.parse(ev.data);
        if (d.kind !== 'dm' || !d.url) return;
        // Only append if the event's conversation URL matches the one we're on.
        if (d.url !== myUrl) return;
        var div = document.createElement('div');
        div.style.cssText = 'margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc;background:#fff9e0;';
        var now = new Date();
        var stamp = now.toLocaleString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}).replace(',','');
        div.innerHTML = '<b>'+escapeHtml(d.sender||'Claude')+'</b> <span class="muted">'+escapeHtml(stamp)+'</span><div class="msg-content">'+escapeHtml(d.snippet||'').replace(/\n/g,'<br>')+'</div>';
        end.parentNode.insertBefore(div, end);
        end.scrollIntoView({behavior:'smooth'});
      } catch (_) {}
    });
  }
})();
</script>
</div><!-- /dm-compose -->
</div><!-- /dm-split -->`, otherID, html.EscapeString(otherName))

	PageFooter(w)
}

// extractReplyTo parses "↳ #N" (possibly with HTML escapes) at the
// very start of the rendered content and returns N. Works on the
// rendered HTML since that's what the DB serves.
func extractReplyTo(content string) int {
	// Rendered content typically begins with "<p>↳ #47\n" or similar.
	s := strings.TrimSpace(content)
	s = strings.TrimPrefix(s, "<p>")
	s = strings.TrimPrefix(s, "↳ #")
	if s == "" {
		return 0
	}
	var n int
	for _, c := range s {
		if c >= '0' && c <= '9' {
			n = n*10 + int(c-'0')
			continue
		}
		break
	}
	return n
}

func stripReplyMarker(content string) string {
	// Drop the entire first <p>↳ #N</p> (or paragraph containing only the marker).
	i := strings.Index(content, "</p>")
	if i < 0 {
		return content
	}
	first := content[:i]
	if !strings.Contains(first, "↳ #") {
		return content
	}
	return strings.TrimLeft(content[i+len("</p>"):], "\n")
}

func handleDMSend(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	recipientIDStr := r.FormValue("to")
	content := strings.TrimSpace(r.FormValue("content"))
	recipientID, _ := strconv.Atoi(recipientIDStr)

	if recipientID == 0 || content == "" {
		http.Error(w, "Missing to or content", http.StatusBadRequest)
		return
	}

	msgID, err := dm.SendDM(userID, recipientID, content)
	if err != nil {
		http.Error(w, "Failed to send message", http.StatusInternalServerError)
		return
	}

	if r.URL.Query().Get("ajax") == "1" {
		var senderName string
		DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&senderName)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"id":          msgID,
			"sender_name": senderName,
			"content":     content,
			"timestamp":   time.Now().Format("Jan 2 15:04"),
		})
		return
	}

	http.Redirect(w, r, fmt.Sprintf("/gopher/dm?user_id=%d", recipientID), http.StatusSeeOther)
}
