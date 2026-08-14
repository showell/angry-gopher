import type { BlockNode, InlineNode } from './nodes';

type Attrs = Record<string, string>;

type El = {
  tag: string;
  attrs: Attrs;
  children: Array<El | string>;
};

const VOID = { img: true, br: true, hr: true };

function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

function parseAttrs(raw: string): Attrs {
  const out: Attrs = {};
  const re = /([:@\w-]+)\s*=\s*"([^"]*)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw))) {
    out[m[1].toLowerCase()] = decodeEntities(m[2]);
  }
  return out;
}

export function parseHtmlForest(html: string): Array<El | string> {
  const root: El = { tag: '#root', attrs: {}, children: [] };
  const stack: El[] = [root];
  let i = 0;
  while (i < html.length) {
    if (html.charCodeAt(i) === 60) {
      const close = html.startsWith('</', i);
      const gt = html.indexOf('>', i + 1);
      if (gt < 0) {
        stack[stack.length - 1].children.push(decodeEntities(html.slice(i)));
        break;
      }
      const inner = html.slice(i + (close ? 2 : 1), gt).trim();
      if (!close && inner.charAt(0) === '!') {
        i = gt + 1;
        continue;
      }
      if (close) {
        const tag = inner.toLowerCase().split(/\s/)[0];
        for (let s = stack.length - 1; s > 0; s--) {
          if (stack[s].tag === tag) {
            stack.length = s;
            break;
          }
        }
        i = gt + 1;
        continue;
      }
      const selfClose = inner.endsWith('/');
      const body = selfClose ? inner.slice(0, -1).trim() : inner;
      const sp = body.search(/\s/);
      const tag = (sp < 0 ? body : body.slice(0, sp)).toLowerCase();
      const attrs = parseAttrs(sp < 0 ? '' : body.slice(sp));
      const el: El = { tag, attrs, children: [] };
      stack[stack.length - 1].children.push(el);
      if (!selfClose && !VOID[tag as keyof typeof VOID]) {
        stack.push(el);
      }
      i = gt + 1;
      continue;
    }
    const next = html.indexOf('<', i);
    const end = next < 0 ? html.length : next;
    const text = decodeEntities(html.slice(i, end));
    if (text) {
      stack[stack.length - 1].children.push(text);
    }
    i = end;
  }
  return root.children;
}

function textOf(nodes: Array<El | string>): string {
  let out = '';
  for (const n of nodes) {
    out += typeof n === 'string' ? n : textOf(n.children);
  }
  return out;
}

function msgIdFromHref(href: string): string | null {
  if (href.indexOf('#msg-') === 0) {
    return href.slice(5);
  }
  return null;
}

function isExternal(href: string): boolean {
  return /:\/\//.test(href);
}

function inlinesOf(nodes: Array<El | string>): InlineNode[] {
  const out: InlineNode[] = [];
  for (const n of nodes) {
    if (typeof n === 'string') {
      if (n) {
        out.push({ kind: 'text', text: n });
      }
      continue;
    }
    if (n.tag === 'br') {
      out.push({ kind: 'br' });
      continue;
    }
    if (n.tag === 'em') {
      out.push({ kind: 'em', children: inlinesOf(n.children) });
      continue;
    }
    if (n.tag === 'strong') {
      out.push({ kind: 'strong', children: inlinesOf(n.children) });
      continue;
    }
    if (n.tag === 'code') {
      out.push({ kind: 'code', text: textOf(n.children) });
      continue;
    }
    if (n.tag === 'a') {
      const href = n.attrs.href || '';
      const cls = n.attrs.class || '';
      if (cls.split(/\s+/).indexOf('msg-ref') >= 0) {
        const id = msgIdFromHref(href) || textOf(n.children).replace(/^MSG_/, '');
        out.push({ kind: 'msgref', id, text: textOf(n.children) || 'MSG_' + id });
        continue;
      }
      out.push({
        kind: 'link',
        href,
        external: isExternal(href) || n.attrs.target === '_blank',
        children: inlinesOf(n.children),
      });
      continue;
    }
    out.push.apply(out, inlinesOf(n.children));
  }
  return out;
}

function dim(v: string | undefined): number | undefined {
  if (!v || !/^\d+$/.test(v)) {
    return undefined;
  }
  const n = parseInt(v, 10);
  return n > 0 ? n : undefined;
}

function blockOf(n: El | string): BlockNode[] {
  if (typeof n === 'string') {
    const t = n.replace(/^\s+|\s+$/g, '');
    return t ? [{ kind: 'p', children: [{ kind: 'text', text: t }] }] : [];
  }
  if (n.tag === 'p') {
    const cls = n.attrs.class || '';
    return [
      {
        kind: 'p',
        children: inlinesOf(n.children),
        malformed: cls.split(/\s+/).indexOf('md-malformed') >= 0,
      },
    ];
  }
  if (/^h[1-6]$/.test(n.tag)) {
    return [{ kind: 'h', level: parseInt(n.tag.slice(1), 10), children: inlinesOf(n.children) }];
  }
  if (n.tag === 'blockquote') {
    return [{ kind: 'blockquote', children: blocksOf(n.children) }];
  }
  if (n.tag === 'ul' || n.tag === 'ol') {
    const items: BlockNode[][] = [];
    for (const c of n.children) {
      if (typeof c !== 'string' && c.tag === 'li') {
        items.push(blocksOf(c.children));
      }
    }
    const start = dim(n.attrs.start);
    return [{ kind: 'list', ordered: n.tag === 'ol', start, items }];
  }
  if (n.tag === 'pre') {
    const cls = n.attrs.class || '';
    if (cls.split(/\s+/).indexOf('chat-quote') >= 0) {
      return [{ kind: 'quote', text: textOf(n.children) }];
    }
    let lang: string | undefined;
    let text = '';
    for (const c of n.children) {
      if (typeof c !== 'string' && c.tag === 'code') {
        const cc = c.attrs.class || '';
        const m = cc.match(/language-([^\s]+)/);
        if (m) {
          lang = m[1];
        }
        text = textOf(c.children);
      }
    }
    if (!text) {
      text = textOf(n.children);
    }
    return [{ kind: 'pre', text, lang }];
  }
  if (n.tag === 'img') {
    const src = n.attrs.src || '';
    if (!src || src.charAt(0) !== '/' || src.indexOf('//') === 0) {
      return [{ kind: 'unknown', text: textOf([n]) || src }];
    }
    return [
      {
        kind: 'img',
        src,
        alt: n.attrs.alt || '',
        width: dim(n.attrs.width),
        height: dim(n.attrs.height),
      },
    ];
  }
  if (n.tag === 'video') {
    const src = n.attrs.src || '';
    if (!src || src.charAt(0) !== '/' || src.indexOf('//') === 0) {
      return [{ kind: 'unknown', text: src }];
    }
    return [{ kind: 'video', src }];
  }
  return blocksOf(n.children);
}

function blocksOf(nodes: Array<El | string>): BlockNode[] {
  const out: BlockNode[] = [];
  for (const n of nodes) {
    out.push.apply(out, blockOf(n));
  }
  return out;
}

export function htmlToNodes(html: string): BlockNode[] {
  return blocksOf(parseHtmlForest(html));
}
