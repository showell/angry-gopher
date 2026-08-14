import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import type { CompositeScreenProps } from '@react-navigation/native';
import type { BottomTabScreenProps } from '@react-navigation/bottom-tabs';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import type { DocListItem } from '../api/types';
import type { MainTabParamList, RootStackParamList } from '../navigation/types';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

type Props = CompositeScreenProps<
  BottomTabScreenProps<MainTabParamList, 'Docs'>,
  NativeStackScreenProps<RootStackParamList>
>;

export function DocsScreen({ navigation }: Props) {
  const { colors } = useTheme();
  const { session } = useSession();
  const [rows, setRows] = useState<DocListItem[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!session) {
      return;
    }
    let cancelled = false;
    session.client
      .docs()
      .then(d => {
        if (!cancelled) {
          setRows(d.docs);
          setLoading(false);
        }
      })
      .catch(e => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : 'Failed to load docs');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [session]);

  return (
    <SafeAreaView
      edges={['top']}
      style={[styles.wrap, { backgroundColor: colors.bg }]}>
      <Text style={[styles.title, { color: colors.fg }]}>Docs</Text>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : rows.length === 0 ? (
        <Text style={{ color: colors.mutedFg, padding: 20 }}>No docs yet.</Text>
      ) : (
        <FlatList
          data={rows}
          keyExtractor={item => item.slug}
          renderItem={({ item }) => (
            <Pressable
              onPress={() =>
                navigation.navigate('Doc', { slug: item.slug, title: item.title })
              }
              style={({ pressed }) => [styles.row, { opacity: pressed ? 0.7 : 1 }]}>
              <Text style={[styles.label, { color: colors.fg }]}>{item.title}</Text>
              <Text style={{ color: colors.mutedFg, fontSize: 12 }}>{item.slug}</Text>
            </Pressable>
          )}
        />
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
  row: { paddingHorizontal: 16, paddingVertical: 14 },
  label: { fontSize: 16, fontWeight: '600', marginBottom: 2 },
});
