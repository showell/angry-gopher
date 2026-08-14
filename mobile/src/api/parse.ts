import type { RecentEvent, Sidebar, TopicRef } from './types';

export function parseEmbeddedJson(html: string, id: string): unknown {
  const needle = 'id="' + id + '"';
  const mark = html.indexOf(needle);
  if (mark < 0) {
    throw new Error('page is missing #' + id);
  }
  const gt = html.indexOf('>', mark);
  if (gt < 0) {
    throw new Error('#' + id + ' is unclosed');
  }
  const from = gt + 1;
  const end = html.indexOf('</script>', from);
  if (end < 0) {
    throw new Error('#' + id + ' is unclosed');
  }
  return JSON.parse(html.slice(from, end).replace(/<\\\//g, '</'));
}

export function parseRecentPage(html: string): RecentEvent[] {
  const parsed = parseEmbeddedJson(html, 'recent-data');
  if (!Array.isArray(parsed)) {
    throw new Error('recent page #recent-data is not an array');
  }
  return parsed as RecentEvent[];
}

export function parseSidebarPage(html: string): Sidebar {
  const parsed = parseEmbeddedJson(html, 'chat-sidebar-data') as Sidebar;
  if (!parsed || !Array.isArray(parsed.conversations)) {
    throw new Error('conversation page is missing sidebar conversations');
  }
  return {
    conversations: parsed.conversations || [],
    pinned_sessions: parsed.pinned_sessions || [],
    sessions: parsed.sessions || [],
  };
}

export function emptySidebar(): Sidebar {
  return { conversations: [], pinned_sessions: [], sessions: [] };
}

export function convKeyFromPath(path: string): string {
  const dm = path.match(/^\/chat\/c\/([^/?#]+)/);
  if (dm) {
    return decodeURIComponent(dm[1]);
  }
  const ch = path.match(/^\/channel\/([^/?#]+)/);
  if (ch) {
    return decodeURIComponent(ch[1]);
  }
  return '';
}

export function applySidebarEvent(
  side: Sidebar,
  evt: { kind: string; [k: string]: unknown },
  convKey: string,
): Sidebar {
  if (evt.kind === 'user-arrived') {
    const userId = String(evt.user_id || '');
    const url = String(evt.url || '');
    if (!userId || !url) {
      return side;
    }
    const id = 'uid:' + userId;
    if (side.conversations.some(c => c.id === id)) {
      return side;
    }
    return {
      ...side,
      conversations: side.conversations.concat([
        {
          id,
          label: String(evt.user_name || userId),
          url,
          active: false,
        },
      ]),
    };
  }
  if (evt.kind === 'topic-added') {
    const sid = String(evt.sid || '');
    const url = String(evt.url || '');
    if (!sid || !url || String(evt.conv || '') !== convKey) {
      return side;
    }
    if (side.sessions.some(s => s.id === sid) || side.pinned_sessions.some(s => s.id === sid)) {
      return side;
    }
    const next = side.sessions.concat([{ id: sid, label: sid, url, active: false }]);
    next.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return { ...side, sessions: next };
  }
  if (evt.kind === 'user-online') {
    const id = 'uid:' + String(evt.user_id || '');
    return {
      ...side,
      conversations: side.conversations.map(c =>
        c.id === id ? { ...c, online: true } : c,
      ),
    };
  }
  return side;
}

export function convBaseFromUrl(url: string): string | null {
  const dm = url.match(/^\/chat\/c\/([^/?#]+)/);
  if (dm) {
    return '/chat/c/' + decodeURIComponent(dm[1]);
  }
  const ch = url.match(/^\/channel\/([^/?#]+)/);
  if (ch) {
    return '/channel/' + decodeURIComponent(ch[1]);
  }
  return null;
}

export function parseTopicHref(href: string): TopicRef | null {
  const trimmed = href.trim();
  const hashAt = trimmed.indexOf('#');
  const path = hashAt >= 0 ? trimmed.slice(0, hashAt) : trimmed;
  const hash = hashAt >= 0 ? trimmed.slice(hashAt + 1) : '';
  const msgId = hash.indexOf('msg-') === 0 ? hash.slice(4) : undefined;

  const dm = path.match(/^\/chat\/c\/([^/]+)\/([^/?#]+)/);
  if (dm) {
    return {
      convBase: '/chat/c/' + decodeURIComponent(dm[1]),
      sid: decodeURIComponent(dm[2]),
      msgId,
    };
  }
  const ch = path.match(/^\/channel\/([^/]+)\/([^/?#]+)/);
  if (ch) {
    return {
      convBase: '/channel/' + decodeURIComponent(ch[1]),
      sid: decodeURIComponent(ch[2]),
      msgId,
    };
  }
  return null;
}

export function channelOf(evt: { dm?: boolean; where?: string }): string {
  if (evt.dm) {
    return '';
  }
  if (evt.where && evt.where.indexOf('in ') === 0) {
    return evt.where.slice(3);
  }
  return '';
}

export function dmPartnerName(evt: {
  who?: string;
  where?: string;
}): string {
  if (evt.who && evt.who !== 'You') {
    return evt.who;
  }
  if (evt.where && evt.where.indexOf('to ') === 0) {
    return evt.where.slice(3);
  }
  return '';
}

export function recentKey(evt: RecentEvent): string {
  return evt.kind === 'chat' ? 'chat:' + evt.url : 'doc:' + evt.slug;
}

export function humanizeAgo(iso: string, nowMs: number): string {
  const d = nowMs - new Date(iso).getTime();
  if (d < 60000) {
    return 'just now';
  }
  const m = Math.floor(d / 60000);
  if (m < 60) {
    return m + 'm';
  }
  const h = Math.floor(m / 60);
  if (h < 24) {
    return h + 'h';
  }
  return Math.floor(h / 24) + 'd';
}

export function formatLocalTime(iso: string): string {
  if (!iso) {
    return '';
  }
  const d = new Date(iso);
  if (isNaN(d.getTime())) {
    return '';
  }
  const day = new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
  }).format(d);
  const time = new Intl.DateTimeFormat(undefined, {
    hour: 'numeric',
    minute: '2-digit',
  }).format(d);
  return day + ' · ' + time;
}

export function sessionOfMsgId(id: string): string | null {
  const cut = id.lastIndexOf('_');
  if (cut <= 0) {
    return null;
  }
  return id.slice(0, cut);
}
