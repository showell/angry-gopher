// Chat surface: a private one-on-one conversation page, a send
// endpoint, and a Server-Sent-Events stream for live delivery.
//
// Privacy is structural: a conversation is always keyed by the current
// user plus the chosen partner, so there is no route to a conversation
// you are not part of. Markdown bodies are rendered + sanitized server
// side (see chat_markdown.go) before they reach either browser.
package views

import (
	"crypto/sha256"
	"encoding/hex"
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
	fmt.Fprint(w, `<p class="chat-views" id="chat-views">`+
		`<a href="#" data-view="rendered" class="active">Rendered</a> · `+
		`<a href="#" data-view="raw">Raw</a> · `+
		`<a href="#" data-view="transcript">Transcript</a></p>`)

	fmt.Fprint(w, `<div class="chat-layout"><div class="chat-history view-rendered" id="chat-history"><div class="chat-bubbles" id="chat-bubbles">`)
	if len(msgs) == 0 {
		fmt.Fprint(w, `<p class="muted" id="chat-empty">No messages yet. Say hello 👋</p>`)
	}
	for i, m := range msgs {
		writeChatBubble(w, m, user, i)
	}
	fmt.Fprint(w, `</div><pre class="chat-transcript" id="chat-transcript">`)
	for i, m := range msgs {
		fmt.Fprintf(w, `<span data-i="%d">%s</span>`, i, html.EscapeString(encodeChatBlock(m)))
	}
	fmt.Fprintf(w, `</pre></div>
<div class="chat-compose">
  <form id="chat-form">
    <textarea id="chat-body" placeholder="Write a message…  Markdown is supported, and longer posts are welcome."></textarea>
    <div class="chat-compose-actions">
      <button type="submit">Send</button>
      <button type="button" id="chat-image-btn">Image</button>
    </div>
  </form>
  <input type="file" id="chat-file" accept="image/png,image/jpeg,image/gif,image/webp" style="display:none">
  <div class="chat-status" id="chat-status"></div>
  <div class="chat-hint">Markdown supported · paste or attach an image · Ctrl/⌘-Enter to send</div>
</div></div>`)

	meJSON, _ := json.Marshal(user)
	partnerJSON, _ := json.Marshal(partner)
	fmt.Fprintf(w, chatScript, meJSON, partnerJSON, len(msgs))

	PageFooter(w)
}

// chatMsgHash is a message's stable 6-hex-uppercase id, used for MSG_
// references. Derived from the (immutable, append-only) index + author +
// timestamp + body, so it's deterministic and need not be stored on disk.
func chatMsgHash(index int, msg ChatMessage) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%d\x00%s\x00%s\x00%s",
		index, msg.From, msg.At.UTC().Format(time.RFC3339), msg.Body)))
	return strings.ToUpper(hex.EncodeToString(sum[:3]))
}

// writeChatBubble renders one message; the JS poller builds the same
// shape from the SSE payload, so server- and live-rendered messages
// match.
func writeChatBubble(w io.Writer, msg ChatMessage, me string, idx int) {
	cls := "theirs"
	if msg.From == me {
		cls = "mine"
	}
	hash := chatMsgHash(idx, msg)
	fmt.Fprintf(w,
		`<div class="chat-msg %s" id="msg-%s" data-i="%d" data-hash="%s">`+
			`<div class="chat-meta">%s · %s <button type="button" class="msg-refer" title="Reference this message">refer</button></div>`+
			`<div class="chat-body">%s</div><div class="chat-raw">%s</div></div>`,
		cls, hash, idx, hash,
		html.EscapeString(msg.From), html.EscapeString(formatChatTime(msg.At)),
		RenderChatMarkdown(msg.Body), html.EscapeString(msg.Body))
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
	Raw   string `json:"raw"`
	Enc   string `json:"enc"`
	Hash  string `json:"hash"`
	Mine  bool   `json:"mine"`
}

func writeChatEvent(w io.Writer, rc *http.ResponseController, evt chatEvent, me string) error {
	wire := chatWireMsg{
		Index: evt.Index,
		From:  evt.Msg.From,
		Time:  formatChatTime(evt.Msg.At),
		HTML:  string(RenderChatMarkdown(evt.Msg.Body)),
		Raw:   evt.Msg.Body,
		Enc:   encodeChatBlock(evt.Msg),
		Hash:  chatMsgHash(evt.Index, evt.Msg),
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
.chat-meta .msg-refer { font-size:10px; color:#888; background:none; border:none;
                        padding:0 2px; cursor:pointer; text-decoration:underline; }
.chat-meta .msg-refer:hover { color:#000080; }
.chat-body a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:0.9em;
                       background:#eaeaff; color:#000080; padding:0 4px; border-radius:3px;
                       text-decoration:none; }
.chat-body a.msg-ref:hover { background:#d8d8ff; }
.msg-flash { animation: msgflash 1.6s ease-out; }
@keyframes msgflash { 0%,12% { box-shadow:0 0 0 3px #ffcf3a; } 100% { box-shadow:0 0 0 3px transparent; } }
.chat-body p:first-child { margin-top:0; }
.chat-body p:last-child { margin-bottom:0; }
.chat-body pre { background:#f4f4ec; padding:8px; border-radius:4px; overflow-x:auto; }
.chat-raw { display:none; white-space:pre-wrap; overflow-wrap:anywhere;
            font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px;
            color:#333; background:#f4f4ec; padding:8px; border-radius:4px; }
.chat-history.view-raw .chat-body { display:none; }
.chat-history.view-raw .chat-raw { display:block; }
.chat-transcript { display:none; margin:0; white-space:pre-wrap; overflow-wrap:anywhere;
                   font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; color:#333; }
.chat-history.view-transcript #chat-bubbles { display:none; }
.chat-history.view-transcript .chat-transcript { display:block; }
.chat-views { margin:-6px 0 12px; font-size:13px; }
.chat-views a { text-decoration:none; }
.chat-views a.active { font-weight:bold; color:#000; cursor:default; }
.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }
.chat-compose-actions button { margin-top:0; }
.chat-body img { max-width:100%; max-height:320px; display:block; margin:6px 0;
                 border-radius:6px; cursor:zoom-in; }
.chat-img-dialog { border:1px solid #000080; border-radius:10px; padding:10px;
                   display:flex; flex-direction:column; gap:8px; }
.chat-img-dialog::backdrop { background:rgba(0,0,0,0.55); }
.chat-img-controls { display:flex; align-items:center; gap:10px; }
.chat-img-controls input[type=range] { flex:1; }
/* Fixed viewport: never resizes, so the slider stays put. The image is
   scaled in px inside it and overflows into scrollbars when zoomed in. */
.chat-img-scroll { width:70vw; height:70vh; overflow:auto; background:#faf9f5; border-radius:6px; }
.chat-img-scroll img { display:block; }
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
  var bubbles=document.getElementById('chat-bubbles');
  var transcript=document.getElementById('chat-transcript');
  var views=document.getElementById('chat-views');
  var form=document.getElementById('chat-form');
  var textarea=document.getElementById('chat-body');
  var status=document.getElementById('chat-status');
  var imageBtn=document.getElementById('chat-image-btn');
  var fileInput=document.getElementById('chat-file');
  function atBottom(){ return history.scrollHeight-history.scrollTop-history.clientHeight < 40; }
  function toBottom(){ history.scrollTop=history.scrollHeight; }
  function addMessage(m){
    var empty=document.getElementById('chat-empty'); if(empty) empty.remove();
    var div=document.createElement('div');
    div.className='chat-msg '+(m.mine?'mine':'theirs');
    div.id='msg-'+m.hash; div.setAttribute('data-i',m.index); div.setAttribute('data-hash',m.hash);
    var meta=document.createElement('div'); meta.className='chat-meta';
    meta.appendChild(document.createTextNode(m.from+' · '+m.time+' '));
    var refer=document.createElement('button'); refer.type='button'; refer.className='msg-refer';
    refer.title='Reference this message'; refer.textContent='refer'; meta.appendChild(refer);
    var body=document.createElement('div'); body.className='chat-body';
    body.innerHTML=m.html; /* sanitized server-side */
    var raw=document.createElement('div'); raw.className='chat-raw';
    raw.textContent=m.raw;
    div.appendChild(meta); div.appendChild(body); div.appendChild(raw);
    bubbles.appendChild(div);
    var span=document.createElement('span'); span.setAttribute('data-i',m.index);
    span.textContent=m.enc; transcript.appendChild(span); /* literal on-disk block */
  }
  /* Anchor scrolling on the same MESSAGE across view switches: find the
     topmost visible [data-i] element, then bring that same index back to
     the top after the layout changes (rendered/raw/transcript differ). */
  function topIndex(){
    var els=history.querySelectorAll('[data-i]'), htop=history.getBoundingClientRect().top;
    for(var i=0;i<els.length;i++){
      if(els[i].offsetParent===null) continue;
      if(els[i].getBoundingClientRect().bottom>htop+1) return els[i].getAttribute('data-i');
    }
    return null;
  }
  function scrollToIndex(idx){
    if(idx===null) return;
    var els=history.querySelectorAll('[data-i="'+idx+'"]');
    for(var i=0;i<els.length;i++){
      if(els[i].offsetParent===null) continue;
      history.scrollTop+=els[i].getBoundingClientRect().top-history.getBoundingClientRect().top;
      return;
    }
  }
  function setView(v){
    var idx=topIndex();
    history.className='chat-history view-'+v;
    var links=views.querySelectorAll('a');
    for(var i=0;i<links.length;i++){ links[i].className=(links[i].getAttribute('data-view')===v)?'active':''; }
    scrollToIndex(idx);
  }
  views.addEventListener('click',function(e){
    var a=e.target.closest('a[data-view]'); if(!a) return;
    e.preventDefault(); setView(a.getAttribute('data-view'));
  });
  toBottom();
  var es=new EventSource('/chat/stream?with='+encodeURIComponent(PARTNER)+'&since='+SINCE);
  es.onmessage=function(e){ var stick=atBottom(); addMessage(JSON.parse(e.data)); if(stick) toBottom(); };
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
  /* --- image upload (button + clipboard paste) --- */
  function insertAtCursor(text){
    var s=textarea.selectionStart, e=textarea.selectionEnd, v=textarea.value;
    textarea.value=v.slice(0,s)+text+v.slice(e);
    textarea.selectionStart=textarea.selectionEnd=s+text.length; textarea.focus();
  }
  function uploadImage(file){
    if(!file) return;
    status.style.color='#888'; status.textContent='Uploading image…';
    var fd=new FormData(); fd.append('file',file);
    fetch('/chat/upload?with='+encodeURIComponent(PARTNER),{method:'POST',body:fd})
      .then(function(r){ if(!r.ok) throw new Error('status '+r.status); return r.json(); })
      .then(function(d){
        var alt=(d.name||'image').replace(/[\[\]\r\n]/g,'');
        insertAtCursor('!['+alt+']('+d.url+')');
        status.textContent=''; status.style.color='';
      })
      .catch(function(){ status.style.color=''; status.textContent='Image upload failed.'; });
  }
  imageBtn.addEventListener('click',function(){ fileInput.click(); });
  fileInput.addEventListener('change',function(){ uploadImage(fileInput.files[0]); fileInput.value=''; });
  textarea.addEventListener('paste',function(e){
    var files=e.clipboardData&&e.clipboardData.files;
    if(files) for(var i=0;i<files.length;i++){
      if(files[i].type.indexOf('image/')===0){ e.preventDefault(); uploadImage(files[i]); return; }
    }
  });
  /* --- click any image to zoom (range slider scales height; scroll to pan) --- */
  function showImagePopup(src){
    var dlg=document.createElement('dialog'); dlg.className='chat-img-dialog';
    var controls=document.createElement('div'); controls.className='chat-img-controls';
    var range=document.createElement('input'); range.type='range';
    range.min='1'; range.max='8'; range.step='0.05'; range.value='1';
    var close=document.createElement('button'); close.type='button'; close.textContent='Close';
    close.addEventListener('click',function(){ dlg.close(); });
    controls.appendChild(range); controls.appendChild(close);
    var scroll=document.createElement('div'); scroll.className='chat-img-scroll';
    var img=document.createElement('img'); img.alt='';
    scroll.appendChild(img);
    dlg.appendChild(controls); dlg.appendChild(scroll);
    dlg.addEventListener('close',function(){ dlg.remove(); });
    document.body.appendChild(dlg);
    /* fitW/fitH = largest size that fits the fixed container (computed once
       the image's natural size + the container size are known); the slider
       then multiplies that, overflowing into scroll when >1. */
    var fitW=0, fitH=0;
    function applyZoom(){ if(!fitW) return; var z=parseFloat(range.value); img.style.width=(fitW*z)+'px'; img.style.height=(fitH*z)+'px'; }
    function fit(){
      var cw=scroll.clientWidth, ch=scroll.clientHeight, nw=img.naturalWidth, nh=img.naturalHeight;
      if(!cw||!ch||!nw||!nh) return;
      var s=Math.min(cw/nw, ch/nh);
      fitW=nw*s; fitH=nh*s; applyZoom();
    }
    range.addEventListener('input', applyZoom);
    dlg.showModal();
    img.addEventListener('load', fit);
    img.src=src;
    if(img.complete) fit();
  }
  function flashMsg(el){ el.classList.remove('msg-flash'); void el.offsetWidth; el.classList.add('msg-flash'); }
  bubbles.addEventListener('click',function(e){
    var t=e.target;
    var rb=t.closest&&t.closest('.msg-refer');
    if(rb){ var mm=rb.closest('.chat-msg'); if(mm) insertAtCursor('MSG_'+mm.getAttribute('data-hash')+' '); return; }
    var a=t.closest&&t.closest('a.msg-ref');
    if(a){ e.preventDefault();
      var tgt=document.getElementById(a.getAttribute('href').slice(1));
      if(tgt){ tgt.scrollIntoView({block:'center',behavior:'smooth'}); flashMsg(tgt); }
      return; }
    if(t&&t.tagName==='IMG'&&t.closest('.chat-body')) showImagePopup(t.src);
  });
  textarea.focus();
})();</script>`
