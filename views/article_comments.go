// Inline article comments — Steve reads linearly and wants to drop
// light notes anchored to the paragraph he just finished.
//
//   GET  /gopher/article-comments?article=<path>
//        Returns the comments JSON for a given article.
//   POST /gopher/article-comments
//        Form: article=<path>, para_index=<n>, author=<name>, text=<...>
//        Appends a comment; returns the updated list.
//
// Comments are stored as a sibling JSON file:
//   foo.md  →  foo.md.comments.json
//
// label: SPIKE (article-comments)
package views

import (
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
)

type articleComment struct {
	ParaIndex int    `json:"para_index"`
	Author    string `json:"author"`
	Timestamp string `json:"timestamp"`
	Text      string `json:"text"`
}

type articleCommentFile struct {
	Comments []articleComment `json:"comments"`
}

// resolveArticlePath takes a path like "gopher/showell/foo.md" and
// returns the absolute filesystem path, refusing anything that
// escapes a known repo root.
func resolveArticlePath(article string) (string, bool) {
	parts := strings.SplitN(strings.TrimPrefix(article, "/"), "/", 2)
	if len(parts) < 2 {
		return "", false
	}
	repo, sub := parts[0], parts[1]
	return resolveRepoPath(repo, sub)
}

func commentsSidecarPath(articleAbs string) string {
	return articleAbs + ".comments.json"
}

func loadArticleComments(articleAbs string) articleCommentFile {
	data, err := os.ReadFile(commentsSidecarPath(articleAbs))
	if err != nil {
		return articleCommentFile{}
	}
	var f articleCommentFile
	if err := json.Unmarshal(data, &f); err != nil {
		return articleCommentFile{}
	}
	return f
}

func saveArticleComments(articleAbs string, f articleCommentFile) error {
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(commentsSidecarPath(articleAbs), data, 0644)
}

func HandleArticleComments(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method == "GET" {
		article := r.URL.Query().Get("article")
		abs, ok := resolveArticlePath(article)
		if !ok {
			http.Error(w, "Invalid article path", http.StatusBadRequest)
			return
		}
		f := loadArticleComments(abs)
		json.NewEncoder(w).Encode(f)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Bad form", http.StatusBadRequest)
		return
	}
	article := r.FormValue("article")
	abs, ok := resolveArticlePath(article)
	if !ok {
		http.Error(w, "Invalid article path", http.StatusBadRequest)
		return
	}
	paraIdx, _ := strconv.Atoi(r.FormValue("para_index"))
	text := strings.TrimSpace(r.FormValue("text"))
	if text == "" {
		http.Error(w, "Empty comment", http.StatusBadRequest)
		return
	}
	// Determine author from auth header; default to Steve (DefaultUserID=1).
	userID := auth.Authenticate(r)
	author := "Steve"
	if userID == 2 {
		author = "Claude"
	}
	// Optional override via form param.
	if a := r.FormValue("author"); a != "" {
		author = a
	}
	f := loadArticleComments(abs)
	f.Comments = append(f.Comments, articleComment{
		ParaIndex: paraIdx,
		Author:    author,
		Timestamp: time.Now().Format(time.RFC3339),
		Text:      text,
	})
	if err := saveArticleComments(abs, f); err != nil {
		http.Error(w, "Cannot save: "+err.Error(), http.StatusInternalServerError)
		return
	}
	json.NewEncoder(w).Encode(f)
}

// ArticleCommentsJS is the client-side script injected into rendered
// markdown articles. It walks the .wiki-md paragraphs, renders any
// existing comments beneath each, and adds an "add comment" affordance.
const ArticleCommentsJS = `
<script>
(function(){
  var container = document.querySelector('.wiki-md');
  if (!container) return;

  // Duplicate the Prev/Next nav block at the bottom — Steve often
  // needs it where he stopped reading, not just at the top.
  (function duplicateNav(){
    var ps = container.querySelectorAll('p');
    var navP = null;
    for (var i = 0; i < ps.length; i++) {
      var t = ps[i].textContent;
      if (t.indexOf('← Prev:') !== -1 || t.indexOf('→ Next:') !== -1) {
        navP = ps[i];
        break;
      }
    }
    if (!navP) return;
    container.appendChild(document.createElement('hr'));
    var clone = navP.cloneNode(true);
    clone.setAttribute('data-nav-footer', '1');  // skip in para indexing
    container.appendChild(clone);
  })();

  // Derive article path from current URL.
  // URLs look like /gopher/docs/<repo>/<sub> or /gopher/code/<repo>/<sub>.
  var path = location.pathname;
  var m = path.match(/^\/gopher\/(?:docs|code)\/(.+)$/);
  if (!m) return;
  var articlePath = m[1];
  if (!articlePath.endsWith('.md')) return;

  // Style block injected once.
  var style = document.createElement('style');
  style.textContent = [
    '.para-wrap { position: relative; }',
    '.para-add-btn { margin-left: 8px; cursor: pointer; font-size: 13px; border: 1px solid #000080; background: white; color: #000080; padding: 1px 6px; border-radius: 3px; vertical-align: middle; }',
    '.para-add-btn:hover { background: #000080; color: white; }',
    '.para-comments { margin: 6px 0 14px 24px; padding-left: 10px; border-left: 3px solid #d6d0be; }',
    '.para-comment { background: #faf7ef; border: 1px solid #e8e1cc; border-radius: 3px; padding: 10px 12px; margin: 6px 0; font-size: 14px; font-family: sans-serif; color: #333; line-height: 1.55; }',
    '.para-comment .meta { color: #888; font-size: 11px; margin-bottom: 2px; }',
    '.para-compose { margin: 6px 0 14px 24px; padding: 8px; background: #fff3a8; border: 1px solid #e6d670; border-radius: 4px; font-family: sans-serif; }',
    '.para-compose textarea { width: 100%; min-height: 120px; padding: 8px 10px; font-size: 14px; font-family: sans-serif; line-height: 1.5; box-sizing: border-box; border: 1px solid #c9bfa7; border-radius: 3px; }',
    '.para-compose button { margin-top: 6px; margin-right: 6px; padding: 4px 12px; font-size: 13px; border: none; border-radius: 3px; cursor: pointer; }',
    '.para-compose .save { background: #000080; color: white; }',
    '.para-compose .cancel { background: #eee; color: #333; }',
  ].join('\n');
  document.head.appendChild(style);

  // Find all commentable blocks: paragraphs + list items. Skip <li>s
  // that already contain a <p> (loose lists) so we don't double-count;
  // the inner <p> gets the button. Skip the nav footer clone.
  var candidates = container.querySelectorAll('p, li');
  var paras = [];
  candidates.forEach(function(el){
    if (el.closest('[data-nav-footer]')) return;
    if (el.tagName === 'LI' && el.querySelector(':scope > p')) return;
    paras.push(el);
  });
  var paraByIndex = {};
  paras.forEach(function(p, i){
    p.setAttribute('data-para-index', i);
    p.classList.add('para-wrap');
    paraByIndex[i] = p;

    var btn = document.createElement('button');
    btn.className = 'para-add-btn';
    btn.textContent = 'note';
    btn.title = 'Add a note on this paragraph';
    btn.addEventListener('click', function(){ openCompose(i); });
    p.appendChild(btn);
  });

  // For a <p>, comment/compose boxes attach as sibling. For a <li>,
  // they attach inside the <li> (to avoid invalid <div> between <li>s).
  function attachAfter(p, child) {
    if (p.tagName === 'LI') {
      p.appendChild(child);
    } else {
      p.parentNode.insertBefore(child, p.nextSibling);
    }
  }
  function findExistingCommentsBox(p) {
    if (p.tagName === 'LI') {
      return p.querySelector(':scope > .para-comments');
    }
    var sib = p.nextElementSibling;
    if (sib && sib.classList.contains('para-comments')) return sib;
    return null;
  }

  // Fetch existing comments.
  fetch('/gopher/article-comments?article=' + encodeURIComponent(articlePath))
    .then(function(r){ return r.ok ? r.json() : { comments: [] }; })
    .then(function(data){
      (data.comments || []).forEach(renderComment);
    });

  function renderComment(c) {
    var p = paraByIndex[c.para_index];
    if (!p) return;
    var box = findExistingCommentsBox(p);
    if (!box) {
      box = document.createElement('div');
      box.className = 'para-comments';
      box.setAttribute('data-para-index', c.para_index);
      attachAfter(p, box);
    }
    var cEl = document.createElement('div');
    cEl.className = 'para-comment';
    var meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = c.author + ' · ' + c.timestamp;
    cEl.appendChild(meta);
    var text = document.createElement('div');
    text.textContent = c.text;
    cEl.appendChild(text);
    box.appendChild(cEl);
    // Subject promises at most one comment per paragraph — hide the
    // add-button once a comment exists.
    var btn = p.querySelector('.para-add-btn');
    if (btn) btn.style.display = 'none';
  }

  function openCompose(paraIdx) {
    // Don't open a second compose for the same para.
    var existing = document.querySelector('.para-compose[data-para-index="' + paraIdx + '"]');
    if (existing) { existing.querySelector('textarea').focus(); return; }

    var p = paraByIndex[paraIdx];
    var compose = document.createElement('div');
    compose.className = 'para-compose';
    compose.setAttribute('data-para-index', paraIdx);
    compose.innerHTML = '<textarea placeholder="Light note..."></textarea>' +
      '<div><button class="save">Save</button><button class="cancel">Cancel</button></div>';

    // Insert after any existing comments box, or directly after the paragraph.
    var existingBox = findExistingCommentsBox(p);
    if (existingBox) {
      existingBox.parentNode.insertBefore(compose, existingBox.nextSibling);
    } else {
      attachAfter(p, compose);
    }

    var textarea = compose.querySelector('textarea');
    textarea.focus();

    compose.querySelector('.cancel').addEventListener('click', function(){
      compose.remove();
    });
    compose.querySelector('.save').addEventListener('click', function(){
      var text = textarea.value.trim();
      if (!text) return;
      var body = new URLSearchParams();
      body.set('article', articlePath);
      body.set('para_index', String(paraIdx));
      body.set('text', text);
      fetch('/gopher/article-comments', {
        method: 'POST',
        headers: {'Content-Type':'application/x-www-form-urlencoded'},
        body: body.toString(),
      }).then(function(r){ return r.ok ? r.json() : Promise.reject(r.status); })
        .then(function(data){
          // Re-render: clear existing comment boxes and redraw.
          document.querySelectorAll('.para-comments').forEach(function(el){ el.remove(); });
          (data.comments || []).forEach(renderComment);
          compose.remove();
        })
        .catch(function(err){
          alert('Failed to save: ' + err);
        });
    });
  }
})();
</script>
`
