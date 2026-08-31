import React, { createContext, useContext, useEffect, useState } from 'react';
import * as Keychain from 'react-native-keychain';
import { ChatClient } from '../api/client';
import type { ConversationsResponse } from '../api/types';
import {
  loadProfiles,
  profileId,
  removeProfile,
  type SavedProfile,
  upsertProfile,
  writeProfiles,
} from './profiles';

const SERVICE = 'org.lynrummy.gopher';

export type Session = {
  client: ChatClient;
  me: string;
  conversations: ConversationsResponse['conversations'];
};

type SessionValue = {
  session: Session | null;
  ready: boolean;
  error: string;
  profiles: SavedProfile[];
  signIn: (base: string, key: string) => Promise<void>;
  signOut: () => Promise<void>;
  forgetProfile: (id: string) => Promise<void>;
};

const SessionContext = createContext<SessionValue>({
  session: null,
  ready: false,
  error: '',
  profiles: [],
  signIn: async () => {},
  signOut: async () => {},
  forgetProfile: async () => {},
});

async function loadStored(): Promise<{ base: string; key: string } | null> {
  const creds = await Keychain.getGenericPassword({ service: SERVICE });
  if (!creds) {
    return null;
  }
  return { base: creds.username, key: creds.password };
}

export function SessionProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState('');
  const [profiles, setProfiles] = useState<SavedProfile[]>([]);

  async function remember(base: string, uid: string, key: string) {
    const next = upsertProfile(await loadProfiles(), {
      id: profileId(base, uid),
      base,
      uid,
      key,
      savedAt: new Date().toISOString(),
    });
    await writeProfiles(next);
    setProfiles(next);
  }

  async function signIn(base: string, key: string) {
    setError('');
    const client = new ChatClient(base, key);
    const matrix = await client.conversations();
    await Keychain.setGenericPassword(client.base, client.key, { service: SERVICE });
    await remember(client.base, matrix.me, client.key);
    setSession({
      client,
      me: matrix.me,
      conversations: matrix.conversations,
    });
  }

  async function signOut() {
    await Keychain.resetGenericPassword({ service: SERVICE });
    setSession(null);
  }

  async function forgetProfile(id: string) {
    const next = removeProfile(await loadProfiles(), id);
    await writeProfiles(next);
    setProfiles(next);
    if (session && profileId(session.client.base, session.me) === id) {
      await signOut();
    }
  }

  useEffect(() => {
    let cancelled = false;
    loadProfiles()
      .then(list => {
        if (!cancelled) {
          setProfiles(list);
        }
      })
      .catch(() => {});
    loadStored()
      .then(stored => {
        if (!stored || cancelled) {
          return;
        }
        return signIn(stored.base, stored.key);
      })
      .catch(() => {
        if (!cancelled) {
          Keychain.resetGenericPassword({ service: SERVICE }).catch(() => {});
        }
      })
      .finally(() => {
        if (!cancelled) {
          setReady(true);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <SessionContext.Provider
      value={{
        session,
        ready,
        error,
        profiles,
        signIn: async (base, key) => {
          try {
            await signIn(base, key);
          } catch (e) {
            const msg = e instanceof Error ? e.message : 'Sign in failed';
            setError(msg);
            throw e;
          }
        },
        signOut,
        forgetProfile,
      }}>
      {children}
    </SessionContext.Provider>
  );
}

export function useSession(): SessionValue {
  return useContext(SessionContext);
}
