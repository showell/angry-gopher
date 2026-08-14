import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import type { CompositeScreenProps } from '@react-navigation/native';
import type { BottomTabScreenProps } from '@react-navigation/bottom-tabs';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import type { SidebarItem } from '../api/types';
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
  const [rows, setRows] = useState<SidebarItem[]>([]);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!session) {
      return;
    }
    let cancelled = false;
    const seed = session.conversations[0];
    const path = seed ? '/chat/c/' + seed.conv : '/chat';
    session.client
      .sidebar(path)
      .then(side => {
        if (!cancelled) {
          setRows(side.conversations);
          setLoading(false);
        }
      })
      .catch(e => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : 'Failed to load chats');
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
      <Text style={[styles.title, { color: colors.fg }]}>Chats</Text>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : (
        <FlatList
          data={rows}
          keyExtractor={item => item.id}
          renderItem={({ item }) => (
            <Pressable
              onPress={() =>
                navigation.navigate('Sessions', {
                  convUrl: item.url,
                  title: item.label,
                })
              }
              style={({ pressed }) => [styles.row, { opacity: pressed ? 0.7 : 1 }]}>
              <View
                style={[
                  styles.dot,
                  {
                    backgroundColor: item.online
                      ? colors.presenceOnline
                      : 'transparent',
                    borderColor: item.online
                      ? colors.presenceOnline
                      : colors.presenceIdle,
                  },
                ]}
              />
              <Text style={[styles.label, { color: colors.fg }]} numberOfLines={1}>
                {item.label}
              </Text>
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
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 14,
    gap: 12,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    borderWidth: 1.5,
  },
  label: { fontSize: 16, fontWeight: '600', flex: 1 },
});
