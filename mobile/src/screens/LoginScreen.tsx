import React, { useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

export function LoginScreen() {
  const { colors } = useTheme();
  const { signIn, error } = useSession();
  const [base, setBase] = useState(
    __DEV__ ? 'http://127.0.0.1:9001' : 'https://lynrummy.com',
  );
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    try {
      await signIn(base.trim(), key.trim());
    } catch {
      /* error lands on the session */
    } finally {
      setBusy(false);
    }
  }

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: colors.bg }}>
    <KeyboardAvoidingView
      style={[styles.wrap, { backgroundColor: colors.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <View style={styles.col}>
        <Text style={[styles.title, { color: colors.fg }]}>Angry Gopher</Text>
        <Text style={[styles.blurb, { color: colors.bodyMutedFg }]}>
          Sign in with a chat API key from Settings on the web. The key is
          stored in the device keychain.
        </Text>
        <Text style={[styles.label, { color: colors.metaFg }]}>Server</Text>
        <TextInput
          testID="login-server"
          value={base}
          onChangeText={setBase}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          placeholder="https://lynrummy.com"
          placeholderTextColor={colors.mutedFg}
          style={[
            styles.input,
            {
              backgroundColor: colors.cardBg,
              color: colors.fg,
              borderColor: colors.inputBorder,
            },
          ]}
        />
        <Text style={[styles.label, { color: colors.metaFg }]}>API key</Text>
        <TextInput
          testID="login-key"
          value={key}
          onChangeText={setKey}
          autoCapitalize="none"
          autoCorrect={false}
          secureTextEntry
          placeholder="id-secret"
          placeholderTextColor={colors.mutedFg}
          style={[
            styles.input,
            {
              backgroundColor: colors.cardBg,
              color: colors.fg,
              borderColor: colors.inputBorder,
            },
          ]}
        />
        {error ? (
          <Text style={{ color: colors.error, marginTop: 8 }}>{error}</Text>
        ) : null}
        <Pressable
          testID="login-submit"
          onPress={submit}
          disabled={busy || !base.trim() || !key.trim()}
          style={[
            styles.btn,
            {
              backgroundColor: colors.accent,
              opacity: busy || !base.trim() || !key.trim() ? 0.5 : 1,
            },
          ]}>
          {busy ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.btnLabel}>Sign in</Text>
          )}
        </Pressable>
      </View>
    </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1, justifyContent: 'center' },
  col: { paddingHorizontal: 24, maxWidth: 440, width: '100%', alignSelf: 'center' },
  title: { fontSize: 28, fontWeight: '800', letterSpacing: -0.8, marginBottom: 8 },
  blurb: { fontSize: 15, lineHeight: 21, marginBottom: 28 },
  label: { fontSize: 13, fontWeight: '600', marginBottom: 6, marginTop: 12 },
  input: {
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 12,
    fontSize: 16,
  },
  btn: {
    marginTop: 24,
    minHeight: 44,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnLabel: { color: '#fff', fontWeight: '700', fontSize: 16 },
});
