import { openEventSource } from './sse';
import { parseRecentPage, parseSidebarPage } from './parse';
import type {
  ConversationsResponse,
  DocListItem,
  RecentEvent,
  Sidebar,
  UploadResult,
  WireMessage,
} from './types';

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export class ChatClient {
  base: string;
  key: string;

  constructor(base: string, key: string) {
    this.base = base.replace(/\/+$/, '');
    this.key = key.trim();
  }

  headers(): Record<string, string> {
    return { Authorization: 'Bearer ' + this.key };
  }

  private async request(path: string, init?: RequestInit): Promise<Response> {
    const headers: Record<string, string> = Object.assign({}, this.headers());
    if (init && init.headers) {
      Object.assign(headers, init.headers as Record<string, string>);
    }
    const res = await fetch(this.base + path, Object.assign({}, init, { headers }));
    return res;
  }

  private async text(path: string): Promise<string> {
    const res = await this.request(path);
    if (!res.ok) {
      throw new ApiError(res.status, await res.text());
    }
    return res.text();
  }

  private async json<T>(path: string): Promise<T> {
    const res = await this.request(path);
    if (!res.ok) {
      throw new ApiError(res.status, await res.text());
    }
    return res.json() as Promise<T>;
  }

  conversations(): Promise<ConversationsResponse> {
    return this.json('/chat/conversations');
  }

  async recent(): Promise<RecentEvent[]> {
    const html = await this.text('/chat/recent');
    return parseRecentPage(html);
  }

  async sidebar(path: string): Promise<Sidebar> {
    const html = await this.text(path);
    return parseSidebarPage(html);
  }

  docs(): Promise<{ me: string; docs: DocListItem[] }> {
    return this.json('/chat/docs/list');
  }

  docMarkdown(slug: string): Promise<string> {
    return this.text('/chat/docs/' + encodeURIComponent(slug) + '.md');
  }

  streamSidebar(
    onEvent: (evt: { kind: string; [k: string]: unknown }) => void,
    onError?: () => void,
  ): () => void {
    return openEventSource(this.base + '/chat/sidebar/stream', this.headers(), {
      onEvent(_event, data) {
        try {
          const parsed = JSON.parse(data) as { kind: string };
          if (parsed && parsed.kind) {
            onEvent(parsed);
          }
        } catch {
          /* keep the stream */
        }
      },
      onError,
    });
  }

  async addTopic(
    convBase: string,
    topic: string,
  ): Promise<{ conv: string; sid: string }> {
    const res = await this.request(convBase + '/new', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'topic=' + encodeURIComponent(topic),
    });
    if (!res.ok) {
      const t = (await res.text()).trim();
      throw new ApiError(res.status, t || 'Add topic failed');
    }
    return res.json() as Promise<{ conv: string; sid: string }>;
  }

  async renderMarkdown(body: string): Promise<string> {
    const res = await this.request('/chat/docs/render', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'body=' + encodeURIComponent(body),
    });
    if (!res.ok) {
      throw new ApiError(res.status, 'Render failed');
    }
    return res.text();
  }

  saved(convBase: string, sid: string): Promise<string[]> {
    return this.json(convBase + '/' + encodeURIComponent(sid) + '/saved');
  }

  async send(
    convBase: string,
    sid: string,
    markdown: string,
    cid: string,
  ): Promise<void> {
    const body =
      'markdown=' +
      encodeURIComponent(markdown) +
      '&cid=' +
      encodeURIComponent(cid);
    const res = await this.request(
      convBase + '/' + encodeURIComponent(sid) + '/send',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Chat-Async': '1',
        },
        body,
      },
    );
    if (!res.ok) {
      const t = (await res.text()).trim();
      throw new ApiError(res.status, t || 'Send failed');
    }
  }

  async upload(
    convBase: string,
    sid: string,
    file: { uri: string; name: string; type: string },
  ): Promise<UploadResult> {
    const form = new FormData();
    form.append('file', {
      uri: file.uri,
      name: file.name,
      type: file.type,
    } as unknown as Blob);
    const res = await this.request(
      convBase + '/' + encodeURIComponent(sid) + '/upload',
      { method: 'POST', body: form },
    );
    if (!res.ok) {
      const t = (await res.text()).trim();
      throw new ApiError(res.status, t || 'Upload failed');
    }
    return res.json() as Promise<UploadResult>;
  }

  async saveToReadingList(fields: {
    conv: string;
    sid: string;
    id: string;
    from: string;
    at: string;
    body: string;
    note: string;
  }): Promise<void> {
    const parts: string[] = [];
    const keys = Object.keys(fields) as Array<keyof typeof fields>;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(fields[k]));
    }
    const res = await this.request('/chat/docs/save_to_reading_list', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: parts.join('&'),
    });
    if (!res.ok) {
      throw new ApiError(res.status, 'Save failed');
    }
  }

  mediaUrl(path: string): { uri: string; headers: Record<string, string> } {
    const url = path.indexOf('http') === 0 ? path : this.base + path;
    return { uri: url, headers: this.headers() };
  }

  streamRecent(onEvent: (evt: RecentEvent) => void, onError?: () => void): () => void {
    return openEventSource(this.base + '/chat/recent/stream', this.headers(), {
      onEvent(_event, data) {
        try {
          const parsed = JSON.parse(data) as RecentEvent;
          if (parsed && parsed.kind && parsed.at) {
            onEvent(parsed);
          }
        } catch {
          /* keep the stream */
        }
      },
      onError,
    });
  }

  streamTopic(
    convBase: string,
    sid: string,
    since: number,
    handlers: {
      onBacklogSize?: (n: number) => void;
      onMessage: (m: WireMessage) => void;
      onError?: () => void;
    },
  ): () => void {
    const path =
      convBase +
      '/' +
      encodeURIComponent(sid) +
      '/stream?since=' +
      encodeURIComponent(String(since));
    return openEventSource(this.base + path, this.headers(), {
      onEvent(event, data) {
        if (event === 'backlog-size') {
          if (handlers.onBacklogSize) {
            handlers.onBacklogSize(parseInt(data, 10) || 0);
          }
          return;
        }
        try {
          handlers.onMessage(JSON.parse(data) as WireMessage);
        } catch {
          /* keep the stream */
        }
      },
      onError: handlers.onError,
    });
  }
}
