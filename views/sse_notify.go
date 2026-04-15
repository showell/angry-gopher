// Live notification stream: Steve's browser subscribes once per
// page, and the bell widget (NotificationWidget) lights up whenever
// Claude posts something (wiki reply, DM).
//
// label: SPIKE (ANCHOR_COMMENTS)
package views

import (
	"fmt"
	"net/http"

	"angry-gopher/notify"
)

// HandleSSEClaudeActivity streams notify.Event JSON blobs as SSE
// `activity` events. Steve's page holds this open for the life of
// the tab.
func HandleSSEClaudeActivity(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	ch, cancel := notify.Subscribe()
	defer cancel()

	fmt.Fprint(w, "event: connected\ndata: ok\n\n")
	flusher.Flush()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case data, ok := <-ch:
			if !ok {
				return
			}
			sseEvent(w, "activity", data)
			flusher.Flush()
		}
	}
}

// NotificationWidget is the HTML+JS fragment injected into every
// page shell. Fixed top-right bell; hidden until an activity event
// fires. Click to navigate, then dismiss.
const NotificationWidget = `
<div id="claude-bell" style="position:fixed;top:10px;right:10px;z-index:9999;
     display:none;background:#fff3a8;border:2px solid #e6a700;border-radius:6px;
     padding:10px 14px;font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,.15);
     width:420px;max-width:90vw;line-height:1.35;">
  <div style="display:flex;justify-content:space-between;align-items:baseline;">
    <span style="font-weight:bold;">🔔 <span id="claude-bell-sender">Claude</span>
      <span id="claude-bell-kind" style="background:#e6a700;color:white;font-size:10px;font-weight:bold;padding:1px 5px;border-radius:2px;margin-left:6px;"></span>
    </span>
    <span id="claude-bell-dismiss" style="cursor:pointer;color:#888;font-size:16px;" title="Dismiss">×</span>
  </div>
  <div id="claude-bell-summary" style="margin-top:4px;color:#444;font-size:12px;"></div>
  <div id="claude-bell-snippet" style="margin-top:6px;color:#222;white-space:pre-wrap;"></div>
  <div style="margin-top:8px;text-align:right;"><a id="claude-bell-link" href="#" style="color:#000080;font-weight:bold;text-decoration:none;">open →</a></div>
</div>
<script>
(function() {
  var bell = document.getElementById('claude-bell');
  if (!bell || !window.EventSource) return;
  var link = document.getElementById('claude-bell-link');
  var sender = document.getElementById('claude-bell-sender');
  var kind = document.getElementById('claude-bell-kind');
  var summary = document.getElementById('claude-bell-summary');
  var snippet = document.getElementById('claude-bell-snippet');
  var dismiss = document.getElementById('claude-bell-dismiss');
  dismiss.addEventListener('click', function(e) {
    e.preventDefault(); e.stopPropagation();
    bell.style.display = 'none';
  });
  var es = new EventSource('/gopher/sse/claude-activity');
  es.addEventListener('activity', function(ev) {
    try {
      var d = JSON.parse(ev.data);
      sender.textContent = d.sender || 'Claude';
      kind.textContent = (d.kind || '').toUpperCase();
      kind.style.display = d.kind ? 'inline' : 'none';
      summary.textContent = d.summary || '';
      snippet.textContent = d.snippet || '';
      link.href = d.url || '#';
      bell.style.display = 'block';
    } catch (_) {}
  });
})();
</script>
`
