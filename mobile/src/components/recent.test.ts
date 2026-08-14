import { canOpenEvent, topicLabel } from './RecentTile';
import { channelColor } from '../theme/colors';

describe('topicLabel / canOpenEvent', () => {
  it('opens a chat only when the href is a topic we can parse', () => {
    expect(
      canOpenEvent({
        kind: 'chat',
        at: 't',
        url: '/chat/c/1_2/ChitChat',
        topic: 'ChitChat',
      }),
    ).toBe(true);
    expect(
      canOpenEvent({ kind: 'chat', at: 't', url: '/chat/recent', topic: 'x' }),
    ).toBe(false);
    expect(canOpenEvent({ kind: 'doc', at: 't', slug: 'reading-list' })).toBe(
      true,
    );
    expect(canOpenEvent({ kind: 'doc', at: 't', slug: '' })).toBe(false);
  });

  it('labels docs by title and chats by topic', () => {
    expect(
      topicLabel({ kind: 'doc', at: 't', slug: 'rl', title: 'Reading list' }),
    ).toBe('Reading list');
    expect(
      topicLabel({ kind: 'chat', at: 't', url: '/chat/c/1_2/yo', topic: 'yo' }),
    ).toBe('yo');
  });
});

describe('channelColor', () => {
  it('is stable for a given channel name', () => {
    expect(channelColor('General')).toBe(channelColor('General'));
    expect(channelColor('General')).not.toBe(channelColor('jobs'));
  });
});
