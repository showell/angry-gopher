import {
  parseProfileStore,
  profileId,
  profileLabel,
  removeProfile,
  type SavedProfile,
  upsertProfile,
} from './profiles';

const ada: SavedProfile = {
  id: 'http://127.0.0.1:9001|4',
  base: 'http://127.0.0.1:9001',
  uid: '4',
  key: '4-aaa',
  savedAt: '2026-08-14T00:00:00Z',
};

describe('saved profiles', () => {
  it('keys a profile by stripped base and uid', () => {
    expect(profileId('http://127.0.0.1:9001/', '4')).toBe(
      'http://127.0.0.1:9001|4',
    );
  });

  it('labels with uid and host', () => {
    expect(profileLabel(ada)).toBe('uid 4 · 127.0.0.1:9001');
  });

  it('upserts to the front and replaces the same id', () => {
    const next = { ...ada, key: '4-bbb', savedAt: '2026-08-14T01:00:00Z' };
    const once = upsertProfile([], ada);
    const twice = upsertProfile(once, next);
    expect(twice).toHaveLength(1);
    expect(twice[0].key).toBe('4-bbb');
    const other = {
      id: 'https://lynrummy.com|2',
      base: 'https://lynrummy.com',
      uid: '2',
      key: '2-ccc',
      savedAt: '2026-08-14T02:00:00Z',
    };
    expect(upsertProfile(twice, other)[0].uid).toBe('2');
    expect(upsertProfile(twice, other)).toHaveLength(2);
  });

  it('removes by id', () => {
    expect(removeProfile([ada], ada.id)).toEqual([]);
    expect(removeProfile([ada], 'missing')).toEqual([ada]);
  });

  it('parses the keychain payload and drops junk', () => {
    expect(parseProfileStore('{"v":1,"items":[' + JSON.stringify(ada) + ']}')).toEqual([
      ada,
    ]);
    expect(parseProfileStore('{"items":[{"id":"x"}]}')).toEqual([]);
  });
});
