import { ApiError, ChatClient } from './client';

type FakeRes = {
  ok: boolean;
  status: number;
  headers: { get: (k: string) => string | null };
  text: () => Promise<string>;
  json: () => Promise<unknown>;
};

function res(
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): FakeRes {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get(k: string) {
        return headers[k] || headers[k.toLowerCase()] || null;
      },
    },
    text: async () => text,
    json: async () => (typeof body === 'string' ? JSON.parse(body) : body),
  };
}

describe('ChatClient', () => {
  const fetchMock = jest.fn();

  beforeEach(() => {
    fetchMock.mockReset();
    global.fetch = fetchMock as unknown as typeof fetch;
  });

  it('strips a trailing slash on the base URL', () => {
    expect(new ChatClient('https://lynrummy.com/', 'k').base).toBe(
      'https://lynrummy.com',
    );
  });

  it('sends markdown + cid as form data with the async header', async () => {
    fetchMock.mockResolvedValue(res(204, ''));
    const c = new ChatClient('https://lynrummy.com', 'key-1');
    await c.send('/chat/c/1_2', 'yo', 'hello there', 'cid-9');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://lynrummy.com/chat/c/1_2/yo/send');
    expect(init.method).toBe('POST');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe('Bearer key-1');
    expect(headers['X-Chat-Async']).toBe('1');
    expect(init.body).toBe('markdown=hello%20there&cid=cid-9');
  });

  it('follows a 303 with GET and keeps the Bearer token', async () => {
    fetchMock
      .mockResolvedValueOnce(
        res(303, '', { Location: '/chat/c/1_2/ChitChat' }),
      )
      .mockResolvedValueOnce(
        res(
          200,
          '<script type="application/json" id="chat-sidebar-data">' +
            '{"conversations":[{"id":"uid:1","label":"Steve","url":"/chat/c/1_2","active":true}],' +
            '"pinned_sessions":[],"sessions":[]}</script>',
        ),
      );
    const c = new ChatClient('https://lynrummy.com', 'key-1');
    const side = await c.sidebar('/chat/c/1_2');
    expect(side.conversations[0].label).toBe('Steve');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const [url1, init1] = fetchMock.mock.calls[0] as [string, RequestInit];
    const [url2, init2] = fetchMock.mock.calls[1] as [string, RequestInit];
    expect(url1).toBe('https://lynrummy.com/chat/c/1_2');
    expect(init1.redirect).toBe('manual');
    expect(url2).toBe('https://lynrummy.com/chat/c/1_2/ChitChat');
    expect(init2.method).toBe('GET');
    expect((init2.headers as Record<string, string>).Authorization).toBe(
      'Bearer key-1',
    );
  });

  it('surfaces a send failure as ApiError', async () => {
    fetchMock.mockResolvedValue(res(503, 'host down'));
    const c = new ChatClient('https://lynrummy.com', 'k');
    await expect(c.send('/chat/c/1_2', 'yo', 'x', 'c')).rejects.toMatchObject({
      name: 'Error',
      status: 503,
      message: 'host down',
    } as Partial<ApiError>);
  });

  it('parses /chat/recent through the embedded JSON slot', async () => {
    fetchMock.mockResolvedValue(
      res(
        200,
        '<script id="recent-data" type="application/json">' +
          '[{"kind":"chat","at":"t","url":"/chat/c/1_2/yo","topic":"yo"}]' +
          '</script>',
      ),
    );
    const rows = await new ChatClient('https://lynrummy.com', 'k').recent();
    expect(rows).toEqual([
      { kind: 'chat', at: 't', url: '/chat/c/1_2/yo', topic: 'yo' },
    ]);
  });

  it('builds a media URL that carries the API key', () => {
    const got = new ChatClient('https://lynrummy.com', 'k').mediaUrl(
      '/chat/c/1_2/t/uploads/a.png',
    );
    expect(got).toEqual({
      uri: 'https://lynrummy.com/chat/c/1_2/t/uploads/a.png',
      headers: { Authorization: 'Bearer k' },
    });
  });
});
