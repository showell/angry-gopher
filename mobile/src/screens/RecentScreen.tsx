import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import type { CompositeScreenProps } from '@react-navigation/native';
import type { BottomTabScreenProps } from '@react-navigation/bottom-tabs';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { parseTopicHref, recentKey } from '../api/parse';
import type { RecentEvent } from '../api/types';
import { canOpenEvent, RecentTile } from '../components/RecentTile';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';
import type { MainTabParamList, RootStackParamList } from '../navigation/types';

type Props = CompositeScreenProps<
  BottomTabScreenProps<MainTabParamList, 'Recent'>,
  NativeStackScreenProps<RootStackParamList>
>;

export function RecentScreen({ navigation }: Props) {
  const { colors } = useTheme();
  const { session } = useSession();
  const [rows, setRows] = useState<RecentEvent[]>([]);
  const [now, setNow] = useState(Date.now());
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 20000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    if (!session) {
      return;
    }
    let stop: (() => void) | undefined;
    let cancelled = false;
    session.client
      .recent()
      .then(initial => {
        if (cancelled) {
          return;
        }
        setRows(initial);
        setLoading(false);
        stop = session.client.streamRecent(evt => {
          setRows(cur => upsert(cur, evt));
        });
      })
      .catch(e => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : 'Failed to load recent');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
      if (stop) {
        stop();
      }
    };
  }, [session]);

  function open(evt: RecentEvent) {
    if (evt.kind === 'doc') {
      navigation.navigate('Doc', {
        slug: evt.slug,
        title: evt.title || evt.slug,
      });
      return;
    }
    const ref = parseTopicHref(evt.url);
    if (!ref) {
      return;
    }
    navigation.navigate('Topic', {
      convBase: ref.convBase,
      sid: ref.sid,
      title: evt.topic || ref.sid,
    });
  }

  return (
    <SafeAreaView
      edges={['top']}
      style={[styles.wrap, { backgroundColor: colors.bg }]}>
      <View
        style={[
          styles.bar,
          { backgroundColor: colors.topBarBg, borderBottomColor: colors.topBarBorder },
        ]}>
        <Text style={[styles.title, { color: colors.fg }]}>Recent</Text>
      </View>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : rows.length === 0 ? (
        <Text style={{ color: colors.mutedFg, padding: 20 }}>Nothing yet.</Text>
      ) : (
        <FlatList
          data={rows}
          keyExtractor={recentKey}
          renderItem={({ item }) => (
            <RecentTile
              event={item}
              colors={colors}
              now={now}
              onPress={() => canOpenEvent(item) && open(item)}
            />
          )}
        />
      )}
    </SafeAreaView>
  );
}

function upsert(rows: RecentEvent[], evt: RecentEvent): RecentEvent[] {
  const key = recentKey(evt);
  const next = rows.filter(r => recentKey(r) !== key);
  next.push(evt);
  next.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  return next;
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  title: { fontSize: 22, fontWeight: '700', letterSpacing: -0.4 },
});
