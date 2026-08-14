import {
  channelOf,
  dmPartnerName,
  humanizeAgo,
  parseRecentPage,
  parseSidebarPage,
  parseTopicHref,
  recentKey,
  sessionOfMsgId,
} from './parse';

describe('parseRecentPage', () => {
  it('extracts the #recent-data array and unescapes script-safe slashes', () => {
    const html =
      '<div id="recent-mount"></div>' +
      '<script id="recent-data" type="application/json">' +
      '[{"kind":"chat","at":"2026-08-14T00:00:00Z","url":"/chat/c/1_2/yo","who":"You","topic":"yo","excerpt":"see <\\/x>","dm":true}]' +
      '</script>';
    const rows = parseRecentPage(html);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('chat');
    if (rows[0].kind === 'chat') {
      expect(rows[0].excerpt).toBe('see </x>');
      expect(rows[0].dm).toBe(true);
    }
  });

  it('throws when the page has no payload', () => {
    expect(() => parseRecentPage('<html></html>')).toThrow(/recent-data/);
  });
});

describe('parseSidebarPage', () => {
  it('reads conversations and sessions from the chat page payload', () => {
    const html =
      '<script type="application/json" id="chat-sidebar-data">' +
      '{"conversations":[{"id":"uid:1","label":"Steve","url":"/chat/c/1_3","active":true}],' +
      '"pinned_sessions":[],' +
      '"sessions":[{"id":"ChitChat","label":"ChitChat","url":"/chat/c/1_3/ChitChat","active":true}]}' +
      '</script>';
    const side = parseSidebarPage(html);
    expect(side.conversations[0].label).toBe('Steve');
    expect(side.sessions[0].url).toBe('/chat/c/1_3/ChitChat');
  });
});

describe('parseTopicHref', () => {
  it('parses a DM topic and optional msg hash', () => {
    expect(parseTopicHref('/chat/c/1_2/ChitChat#msg-ChitChat_12')).toEqual({
      convBase: '/chat/c/1_2',
      sid: 'ChitChat',
      msgId: 'ChitChat_12',
    });
  });

  it('parses a channel topic', () => {
    expect(parseTopicHref('/channel/General/ops-start')).toEqual({
      convBase: '/channel/General',
      sid: 'ops-start',
      msgId: undefined,
    });
  });

  it('returns null for a foreign URL', () => {
    expect(parseTopicHref('https://example.com')).toBeNull();
  });
});

describe('recent helpers', () => {
  it('labels a channel from where', () => {
    expect(channelOf({ where: 'in General' })).toBe('General');
    expect(channelOf({ dm: true, where: 'to Steve' })).toBe('');
  });

  it('names a DM partner from who or where', () => {
    expect(dmPartnerName({ who: 'Steve' })).toBe('Steve');
    expect(dmPartnerName({ who: 'You', where: 'to Steve' })).toBe('Steve');
  });

  it('keys chat vs doc events', () => {
    expect(
      recentKey({
        kind: 'chat',
        at: 't',
        url: '/chat/c/1_2/yo',
      }),
    ).toBe('chat:/chat/c/1_2/yo');
    expect(recentKey({ kind: 'doc', at: 't', slug: 'reading-list' })).toBe(
      'doc:reading-list',
    );
  });

  it('humanizes relative time the way recent.js does', () => {
    const now = Date.parse('2026-08-14T12:00:00Z');
    expect(humanizeAgo('2026-08-14T11:59:30Z', now)).toBe('just now');
    expect(humanizeAgo('2026-08-14T11:50:00Z', now)).toBe('10m');
    expect(humanizeAgo('2026-08-14T09:00:00Z', now)).toBe('3h');
    expect(humanizeAgo('2026-08-12T12:00:00Z', now)).toBe('2d');
  });

  it('splits a message id into its session', () => {
    expect(sessionOfMsgId('ChitChat_12')).toBe('ChitChat');
    expect(sessionOfMsgId('2026-05-28_5')).toBe('2026-05-28');
    expect(sessionOfMsgId('nope')).toBeNull();
  });
});
