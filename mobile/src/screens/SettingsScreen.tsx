import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { profileId, profileLabel } from '../session/profiles';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

export function SettingsScreen() {
  const { colors, mode, toggle } = useTheme();
  const { session, signOut, profiles, forgetProfile } = useSession();
  const currentId = session ? profileId(session.client.base, session.me) : '';

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
      {profiles.length ? (
        <View style={{ marginTop: 8 }}>
          <Text style={[styles.muted, { color: colors.metaFg, fontWeight: '600' }]}>
            Saved on this device
          </Text>
          {profiles.map(p => (
            <Text key={p.id} style={[styles.muted, { marginTop: 4 }]}>
              {profileLabel(p)}
              {p.id === currentId ? ' · current' : ''}
            </Text>
          ))}
        </View>
      ) : null}
      <Pressable
        onPress={toggle}
        style={[styles.btn, { borderColor: colors.border }]}>
        <Text style={{ color: colors.fg, fontWeight: '600' }}>
          Theme: {mode === 'dark' ? 'dark' : 'light'}
        </Text>
      </Pressable>
      <Pressable
        testID="sign-out"
        onPress={() => {
          signOut().catch(() => {});
        }}
        style={[styles.btn, { borderColor: colors.error }]}>
        <Text style={{ color: colors.error, fontWeight: '600' }}>Sign out</Text>
      </Pressable>
      {currentId ? (
        <Pressable
          testID="forget-profile"
          onPress={() => {
            forgetProfile(currentId).catch(() => {});
          }}
          style={[styles.btn, { borderColor: colors.error }]}>
          <Text style={{ color: colors.error, fontWeight: '600' }}>
            Forget this login
          </Text>
        </Pressable>
      ) : null}
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
