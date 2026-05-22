// Chat surface: a private one-on-one conversation page, a send
// endpoint, and a Server-Sent-Events stream for live delivery.
//
// Privacy is structural: a conversation is always keyed by the current
// user plus the chosen partner, so there is no route to a conversation
// you are not part of. Markdown bodies are rendered + sanitized server
// side (see chat_markdown.go) before they reach either browser.
package views

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
)

// maxChatMessageBytes caps a single posted message. Generous — we want
// to encourage longer posts — but bounded.
const maxChatMessageBytes = 64 * 1024

// easternLoc formats message times in the same zone as the rest of the
// site; falls back to UTC if the zoneinfo isn't available.
var easternLoc = func() *time.Location {
	if loc, err := time.LoadLocation("America/New_York"); err == nil {
		return loc
	}
	return time.UTC
}()

func formatChatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.In(easternLoc).Format("Jan 2 · 3:04 PM")
}

// HandleChat serves /chat: a conversation when ?with=<partner> names a
// valid partner, otherwise a small people-picker.
func HandleChat(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat" {
		http.NotFound(w, r)
		return
	}
	user := CurrentUser(r)
	partner := auth.SanitizeUser(r.URL.Query().Get("with"))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if partner == "" || partner == user || !UserExists(partner) {
		renderChatPicker(w, user)
		return
	}
	renderChatConversation(w, user, partner)
}

// renderChatPicker lists everyone you can message (the roster minus
// yourself). The all-users story is mostly this list growing.
func renderChatPicker(w http.ResponseWriter, user string) {
	PageHeader(w, "Messages", user)
	fmt.Fprint(w, `<p class="muted">Pick someone to message:</p><ul>`)
	n := 0
	for _, u := range listUsers() {
		if u == user {
			continue
		}
		fmt.Fprintf(w, `<li><a href="/chat?with=%s">%s</a></li>`,
			url.QueryEscape(u), html.EscapeString(u))
		n++
	}
	if n == 0 {
		fmt.Fprint(w, `<li class="muted">No one else has logged in yet.</li>`)
	}
	fmt.Fprint(w, `</ul>`)
	PageFooter(w)
}

func renderChatConversation(w http.ResponseWriter, user, partner string) {
	msgs, err := ReadChatMessages(user, partner)
	if err != nil {
		http.Error(w, "read conversation: "+err.Error(), http.StatusInternalServerError)
		return
	}

	PageHeader(w, "Chat with "+partner, user)
	fmt.Fprint(w, chatCSS)

	fmt.Fprint(w, `<div class="chat-layout"><div class="chat-history" id="chat-history">`)
	if len(msgs) == 0 {
		fmt.Fprint(w, `<p class="muted" id="chat-empty">No messages yet. Say hello 👋</p>`)
	}
	for _, m := range msgs {
		writeChatBubble(w, m, user)
	}
	fmt.Fprintf(w, `</div>
<div class="chat-compose">
  <form id="chat-form">
    <textarea id="chat-body" placeholder="Write a message…  Markdown is supported, and longer posts are welcome."></textarea>
    <button type="submit">Send</button>
  </form>
  <div class="chat-status" id="chat-status"></div>
  <div class="chat-hint">Markdown supported · Ctrl/⌘-Enter to send · Enter for a new line</div>
</div></div>`)

	meJSON, _ := json.Marshal(user)
	partnerJSON, _ := json.Marshal(partner)
	fmt.Fprintf(w, chatScript, meJSON, partnerJSON, len(msgs))

	PageFooter(w)
}

// writeChatBubble renders one message; the JS poller builds the same
// shape from the SSE payload, so server- and live-rendered messages
// match.
func writeChatBubble(w io.Writer, msg ChatMessage, me string) {
	cls := "theirs"
	if msg.From == me {
		cls = "mine"
	}
	fmt.Fprintf(w,
		`<div class="chat-msg %s"><div class="chat-meta">%s · %s</div><div class="chat-body">%s</div></div>`,
		cls, html.EscapeString(msg.From), html.EscapeString(formatChatTime(msg.At)),
		RenderChatMarkdown(msg.Body))
}

// HandleChatSend appends a posted message. Async (fetch) callers send
// X-Chat-Async and get 204; a plain form post gets a redirect back to
// the conversation (no-JS fallback).
func HandleChatSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user := CurrentUser(r)

	r.Body = http.MaxBytesReader(w, r.Body, maxChatMessageBytes)
	if err := r.ParseForm(); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "message too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	partner := auth.SanitizeUser(r.FormValue("with"))
	body := strings.TrimSpace(r.FormValue("body"))
	async := r.Header.Get("X-Chat-Async") == "1"

	if partner == "" || partner == user || !UserExists(partner) {
		http.Error(w, "unknown conversation partner", http.StatusBadRequest)
		return
	}
	if body == "" {
		chatSendDone(w, r, partner, async)
		return
	}
	if _, err := AppendChatMessage(user, partner, body); err != nil {
		http.Error(w, "save message: "+err.Error(), http.StatusInternalServerError)
		return
	}
	chatSendDone(w, r, partner, async)
}

func chatSendDone(w http.ResponseWriter, r *http.Request, partner string, async bool) {
	if async {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/chat?with="+url.QueryEscape(partner), http.StatusSeeOther)
}

// HandleChatStream is the SSE endpoint. It replays from `since` (or the
// Last-Event-ID on reconnect) and then streams live messages until the
// client disconnects.
func HandleChatStream(w http.ResponseWriter, r *http.Request) {
	user := CurrentUser(r)
	partner := auth.SanitizeUser(r.URL.Query().Get("with"))
	if partner == "" || partner == user || !UserExists(partner) {
		http.Error(w, "unknown conversation partner", http.StatusBadRequest)
		return
	}

	since := 0
	if lei := strings.TrimSpace(r.Header.Get("Last-Event-ID")); lei != "" {
		if n, err := strconv.Atoi(lei); err == nil {
			since = n + 1
		}
	} else if q := r.URL.Query().Get("since"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n >= 0 {
			since = n
		}
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	// This connection is long-lived; clear the server's 30s WriteTimeout
	// so it isn't torn down mid-stream.
	_ = rc.SetWriteDeadline(time.Time{})

	backlog, ch, cancel := OpenChatStream(user, partner, since)
	defer cancel()

	for _, evt := range backlog {
		if writeChatEvent(w, rc, evt, user) != nil {
			return
		}
	}
	if rc.Flush() != nil {
		return
	}

	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case evt, ok := <-ch:
			if !ok {
				return
			}
			if writeChatEvent(w, rc, evt, user) != nil {
				return
			}
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		}
	}
}

// chatWireMsg is the JSON payload of one SSE message event.
type chatWireMsg struct {
	Index int    `json:"index"`
	From  string `json:"from"`
	Time  string `json:"time"`
	HTML  string `json:"html"`
	Mine  bool   `json:"mine"`
}

func writeChatEvent(w io.Writer, rc *http.ResponseController, evt chatEvent, me string) error {
	wire := chatWireMsg{
		Index: evt.Index,
		From:  evt.Msg.From,
		Time:  formatChatTime(evt.Msg.At),
		HTML:  string(RenderChatMarkdown(evt.Msg.Body)),
		Mine:  evt.Msg.From == me,
	}
	data, err := json.Marshal(wire)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "id: %d\ndata: %s\n\n", evt.Index, data); err != nil {
		return err
	}
	return rc.Flush()
}

const chatCSS = `<style>
.chat-layout { display:flex; gap:20px; align-items:flex-start; }
.chat-history { flex:1; min-width:0; max-height:62vh; overflow-y:auto;
                border:1px solid #ddd; border-radius:8px; padding:12px; background:#fcfcf8; }
.chat-compose { width:300px; flex:none; position:sticky; top:16px; }
.chat-compose form { margin:0; }
.chat-compose textarea { width:100%; min-height:200px; resize:vertical; box-sizing:border-box;
                         font-family:inherit; font-size:14px; padding:8px; }
.chat-compose button { margin-top:8px; }
.chat-msg { margin:0 0 12px; padding:8px 10px; border-radius:8px; max-width:88%; }
.chat-msg.mine { background:#e7e7ff; margin-left:auto; }
.chat-msg.theirs { background:#f0f0e6; margin-right:auto; }
.chat-meta { font-size:11px; color:#888; margin-bottom:3px; }
.chat-body p:first-child { margin-top:0; }
.chat-body p:last-child { margin-bottom:0; }
.chat-body pre { background:#f4f4ec; padding:8px; border-radius:4px; overflow-x:auto; }
.chat-hint { font-size:12px; color:#999; margin-top:8px; }
.chat-status { font-size:12px; color:#b00020; min-height:16px; margin-top:6px; }
@media (max-width: 640px) {
  .chat-layout { flex-direction:column; }
  .chat-compose { width:auto; position:static; }
}
</style>`

// chatScript takes ME (json), PARTNER (json), SINCE (int).
const chatScript = `<script>(function(){
  var ME=%s, PARTNER=%s, SINCE=%d;
  var history=document.getElementById('chat-history');
  var form=document.getElementById('chat-form');
  var textarea=document.getElementById('chat-body');
  var status=document.getElementById('chat-status');
  function atBottom(){ return history.scrollHeight-history.scrollTop-history.clientHeight < 40; }
  function toBottom(){ history.scrollTop=history.scrollHeight; }
  function addBubble(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    var div=document.createElement('div');
    div.className='chat-msg '+(m.mine?'mine':'theirs');
    var meta=document.createElement('div'); meta.className='chat-meta';
    meta.textContent=m.from+' · '+m.time;
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    div.appendChild(meta); div.appendChild(body); history.appendChild(div);
  }
  toBottom();
  var es=new EventSource('/chat/stream?with='+encodeURIComponent(PARTNER)+'&since='+SINCE);
  es.onmessage=function(e){ var stick=atBottom(); addBubble(JSON.parse(e.data)); if(stick) toBottom(); };
  function send(){
    var text=textarea.value;
    if(!text.trim()) return;
    textarea.value=''; status.textContent='';
    fetch('/chat/send',{ method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded','X-Chat-Async':'1'},
      body:'with='+encodeURIComponent(PARTNER)+'&body='+encodeURIComponent(text)
    }).then(function(r){ if(!r.ok) throw new Error('status '+r.status); textarea.focus(); })
      .catch(function(){ textarea.value=text; status.textContent='Failed to send — your text is preserved.'; });
  }
  form.addEventListener('submit',function(e){ e.preventDefault(); send(); });
  textarea.addEventListener('keydown',function(e){
    if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); send(); }
  });
  textarea.focus();
})();</script>`
