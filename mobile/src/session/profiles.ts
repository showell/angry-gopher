import * as Keychain from 'react-native-keychain';

export const PROFILES_SERVICE = 'org.lynrummy.gopher.profiles';

export type SavedProfile = {
  id: string;
  base: string;
  uid: string;
  key: string;
  savedAt: string;
};

export function profileId(base: string, uid: string): string {
  return base.replace(/\/+$/, '') + '|' + uid;
}

export function profileLabel(p: SavedProfile): string {
  let host = p.base;
  try {
    const u = new URL(p.base);
    host = u.host || p.base;
  } catch {
    /* keep the raw base */
  }
  return 'uid ' + p.uid + ' · ' + host;
}

export function upsertProfile(list: SavedProfile[], next: SavedProfile): SavedProfile[] {
  const rest = list.filter(p => p.id !== next.id);
  return [next].concat(rest);
}

export function removeProfile(list: SavedProfile[], id: string): SavedProfile[] {
  return list.filter(p => p.id !== id);
}

export function parseProfileStore(raw: string): SavedProfile[] {
  const parsed = JSON.parse(raw) as { items?: SavedProfile[] };
  if (!parsed || !Array.isArray(parsed.items)) {
    return [];
  }
  return parsed.items.filter(
    p => p && p.id && p.base && p.uid && p.key,
  );
}

export async function loadProfiles(): Promise<SavedProfile[]> {
  const creds = await Keychain.getGenericPassword({ service: PROFILES_SERVICE });
  if (!creds || !creds.password) {
    return [];
  }
  try {
    return parseProfileStore(creds.password);
  } catch {
    return [];
  }
}

export async function writeProfiles(list: SavedProfile[]): Promise<void> {
  await Keychain.setGenericPassword('profiles', JSON.stringify({ v: 1, items: list }), {
    service: PROFILES_SERVICE,
  });
}
