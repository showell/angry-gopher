import React from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

export function SettingsScreen() {
  const { colors, mode, toggle } = useTheme();
  const { session, signOut } = useSession();

  return (
    <SafeAreaView
      edges={['top']}
      style={[styles.wrap, { backgroundColor: colors.bg }]}>
      <Text style={[styles.row, { color: colors.fg }]}>
        Signed in as uid {session?.me || '?'}
      </Text>
      <Text style={[styles.muted, { color: colors.mutedFg }]}>
        {session?.client.base}
      </Text>
      <Pressable
        onPress={toggle}
        style={[styles.btn, { borderColor: colors.border }]}>
        <Text style={{ color: colors.fg, fontWeight: '600' }}>
          Theme: {mode === 'dark' ? 'dark' : 'light'}
        </Text>
      </Pressable>
      <Pressable
        onPress={() => {
          signOut().catch(() => {});
        }}
        style={[styles.btn, { borderColor: colors.error }]}>
        <Text style={{ color: colors.error, fontWeight: '600' }}>Sign out</Text>
      </Pressable>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1, padding: 20, gap: 12 },
  row: { fontSize: 16, fontWeight: '600' },
  muted: { fontSize: 13 },
  btn: {
    minHeight: 44,
    borderWidth: 1,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 8,
  },
});
