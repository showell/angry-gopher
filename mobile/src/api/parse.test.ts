import {
  applySidebarEvent,
  channelOf,
  convBaseFromUrl,
  convKeyFromPath,
  topicPeerLabel,
  dmPartnerName,
  emptySidebar,
  humanizeAgo,
  parseChatRootAttrs,
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

describe('parseChatRootAttrs', () => {
  it('reads data-conv, data-conv-base, and data-session', () => {
    const html =
      '<div id="chat-root" data-conv="1_3" data-conv-base="/chat/c/1_3" data-session="ChitChat">';
    expect(parseChatRootAttrs(html)).toEqual({
      conv: '1_3',
      convBase: '/chat/c/1_3',
      session: 'ChitChat',
    });
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

describe('applySidebarEvent', () => {
  it('appends a partner, a same-conv topic, and an online flip', () => {
    let side = emptySidebar();
    side = applySidebarEvent(
      side,
      { kind: 'user-arrived', user_id: '1', user_name: 'Steve', url: '/chat/c/1_3' },
      '1_3',
    );
    side = applySidebarEvent(
      side,
      { kind: 'topic-added', conv: '1_3', sid: 'yo', url: '/chat/c/1_3/yo' },
      '1_3',
    );
    side = applySidebarEvent(side, { kind: 'user-online', user_id: '1' }, '1_3');
    expect(side.conversations[0]).toMatchObject({
      id: 'uid:1',
      label: 'Steve',
      online: true,
    });
    expect(side.sessions[0].id).toBe('yo');
  });

  it('ignores a topic-added for another conversation', () => {
    const side = applySidebarEvent(
      emptySidebar(),
      { kind: 'topic-added', conv: 'other', sid: 'x', url: '/chat/c/x/x' },
      '1_3',
    );
    expect(side.sessions).toHaveLength(0);
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

  it('reads a conversation key and base from a path', () => {
    expect(convKeyFromPath('/chat/c/1_2/ChitChat')).toBe('1_2');
    expect(convKeyFromPath('/channel/General/ops')).toBe('General');
    expect(convBaseFromUrl('/chat/c/1_2/ChitChat')).toBe('/chat/c/1_2');
    expect(convBaseFromUrl('/channel/General/ops')).toBe('/channel/General');
    expect(convBaseFromUrl('/chat/recent')).toBeNull();
  });

  it('names the DM partner or the channel for the topic header', () => {
    const convs = [{ conv: '4_5', partner: { name: 'Sam' } }];
    expect(topicPeerLabel('/chat/c/4_5', convs)).toBe('Sam');
    expect(topicPeerLabel('/chat/c/1_2', convs)).toBeNull();
    expect(topicPeerLabel('/channel/General', [])).toBe('#General');
  });
});
