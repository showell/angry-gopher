import React, { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import type { CompositeScreenProps } from '@react-navigation/native';
import type { BottomTabScreenProps } from '@react-navigation/bottom-tabs';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import {
  applySidebarEvent,
  convBaseFromUrl,
  convKeyFromPath,
  emptySidebar,
  parseTopicHref,
} from '../api/parse';
import type { Sidebar, SidebarItem } from '../api/types';
import { ChatSidebar } from '../components/ChatSidebar';
import type { MainTabParamList, RootStackParamList } from '../navigation/types';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

type Props = CompositeScreenProps<
  BottomTabScreenProps<MainTabParamList, 'Chats'>,
  NativeStackScreenProps<RootStackParamList>
>;

export function ChatsScreen({ navigation }: Props) {
  const { colors } = useTheme();
  const { session } = useSession();
  const [path, setPath] = useState('');
  const [data, setData] = useState<Sidebar>(emptySidebar());
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const convKey = convKeyFromPath(path);
  const convBase = convBaseFromUrl(path) || path;

  useEffect(() => {
    if (!session) {
      return;
    }
    const seed = session.conversations[0];
    load(
      seed
        ? '/chat/c/' + seed.conv + '/' + encodeURIComponent(seed.default)
        : '/chat',
    );
  }, [session]);

  useEffect(() => {
    if (!session) {
      return;
    }
    return session.client.streamSidebar(evt => {
      setData(cur => applySidebarEvent(cur, evt, convKey));
    });
  }, [session, convKey]);

  function load(next: string) {
    if (!session) {
      return;
    }
    setLoading(true);
    setError('');
    setPath(next);
    session.client
      .sidebar(next)
      .then(side => {
        setData(side);
        setLoading(false);
      })
      .catch(e => {
        setError(e instanceof Error ? e.message : 'Failed to load sidebar');
        setLoading(false);
      });
  }

  function openSession(item: SidebarItem) {
    const ref = parseTopicHref(item.url);
    const base = ref ? ref.convBase : convBaseFromUrl(item.url);
    const sid = ref ? ref.sid : item.id;
    if (!base || !sid) {
      return;
    }
    navigation.navigate('Topic', { convBase: base, sid, title: item.label });
  }

  return (
    <SafeAreaView
      edges={['top']}
      style={[styles.wrap, { backgroundColor: colors.bg }]}>
      <Text style={[styles.title, { color: colors.fg }]}>Chats</Text>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : (
        <View style={styles.body}>
          <ChatSidebar
            data={data}
            colors={colors}
            onSelectConversation={item => load(item.url)}
            onSelectSession={openSession}
            onAddTopic={async name => {
              const j = await session!.client.addTopic(convBase, name);
              openSession({
                id: j.sid,
                label: j.sid,
                url: convBase + '/' + j.sid,
              });
            }}
          />
        </View>
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  title: {
    fontSize: 22,
    fontWeight: '700',
    letterSpacing: -0.4,
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 10,
  },
  body: { flex: 1, paddingLeft: 16 },
});
