import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { convBaseFromUrl, parseTopicHref } from '../api/parse';
import type { SidebarItem } from '../api/types';
import type { RootStackParamList } from '../navigation/types';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

type Props = NativeStackScreenProps<RootStackParamList, 'Sessions'>;

export function SessionsScreen({ route, navigation }: Props) {
  const { convUrl, title } = route.params;
  const { colors } = useTheme();
  const { session } = useSession();
  const [pinned, setPinned] = useState<SidebarItem[]>([]);
  const [sessions, setSessions] = useState<SidebarItem[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    navigation.setOptions({ title });
  }, [navigation, title]);

  useEffect(() => {
    if (!session) {
      return;
    }
    let cancelled = false;
    session.client
      .sidebar(convUrl)
      .then(side => {
        if (cancelled) {
          return;
        }
        setPinned(side.pinned_sessions);
        setSessions(side.sessions);
        setLoading(false);
      })
      .catch(e => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : 'Failed to load topics');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [session, convUrl]);

  function open(item: SidebarItem) {
    const ref = parseTopicHref(item.url);
    const base = ref ? ref.convBase : convBaseFromUrl(item.url);
    const sid = ref ? ref.sid : item.id;
    if (!base || !sid) {
      return;
    }
    navigation.navigate('Topic', { convBase: base, sid, title: item.label });
  }

  const rows: Array<{ kind: 'head' | 'item'; key: string; label?: string; item?: SidebarItem }> =
    [];
  if (pinned.length) {
    rows.push({ kind: 'head', key: 'pinned', label: 'Pinned' });
    pinned.forEach(item => rows.push({ kind: 'item', key: 'p:' + item.id, item }));
  }
  if (sessions.length) {
    rows.push({ kind: 'head', key: 'topics', label: 'Topics' });
    sessions.forEach(item => rows.push({ kind: 'item', key: 's:' + item.id, item }));
  }

  return (
    <View style={[styles.wrap, { backgroundColor: colors.bg }]}>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : rows.length === 0 ? (
        <Text style={{ color: colors.mutedFg, padding: 20 }}>No topics yet.</Text>
      ) : (
        <FlatList
          data={rows}
          keyExtractor={r => r.key}
          renderItem={({ item }) =>
            item.kind === 'head' ? (
              <Text style={[styles.head, { color: colors.mutedFg }]}>{item.label}</Text>
            ) : (
              <Pressable
                onPress={() => item.item && open(item.item)}
                style={({ pressed }) => [styles.row, { opacity: pressed ? 0.7 : 1 }]}>
                <Text style={[styles.label, { color: colors.fg }]}>{item.item?.label}</Text>
              </Pressable>
            )
          }
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  head: {
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 0.8,
    textTransform: 'uppercase',
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 6,
  },
  row: { paddingHorizontal: 16, paddingVertical: 14 },
  label: { fontSize: 16, fontWeight: '600' },
});
