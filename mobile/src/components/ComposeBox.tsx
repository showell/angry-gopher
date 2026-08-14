import React from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import type { Palette } from '../theme/colors';

type Props = {
  colors: Palette;
  disabled: boolean;
  status: string;
  statusError: boolean;
  sending: boolean;
  onSend: (text: string) => void;
  onUpload: () => void;
  draft: string;
  onDraft: (text: string) => void;
};

export function ComposeBox({
  colors,
  disabled,
  status,
  statusError,
  sending,
  onSend,
  onUpload,
  draft,
  onDraft,
}: Props) {
  return (
    <View
      style={[
        styles.wrap,
        { backgroundColor: colors.topBarBg, borderTopColor: colors.topBarBorder },
      ]}>
      <TextInput
        testID="compose-input"
        value={draft}
        onChangeText={onDraft}
        editable={!disabled}
        multiline
        placeholder="Write a message…  Markdown is supported."
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
      <View style={styles.row}>
        <Pressable
          onPress={onUpload}
          disabled={disabled}
          style={[
            styles.btn,
            { borderColor: colors.border, opacity: disabled ? 0.5 : 1 },
          ]}>
          <Text style={{ color: colors.fg, fontWeight: '600' }}>Upload</Text>
        </Pressable>
        <Pressable
          testID="compose-send"
          onPress={() => onSend(draft)}
          disabled={disabled || !draft.trim()}
          style={[
            styles.btn,
            styles.send,
            {
              backgroundColor: colors.accent,
              opacity: disabled || !draft.trim() ? 0.5 : 1,
            },
          ]}>
          {sending ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.sendLabel}>Send</Text>
          )}
        </Pressable>
      </View>
      {status ? (
        <Text style={{ color: statusError ? colors.error : colors.mutedFg, marginTop: 6 }}>
          {status}
        </Text>
      ) : (
        <Text style={{ color: colors.softMutedFg, fontSize: 12, marginTop: 6 }}>
          Markdown · image or screencast
        </Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    paddingHorizontal: 12,
    paddingTop: 8,
    paddingBottom: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  input: {
    minHeight: 56,
    maxHeight: 160,
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 8,
    fontSize: 16,
  },
  row: {
    flexDirection: 'row',
    gap: 8,
    marginTop: 8,
  },
  btn: {
    minHeight: 44,
    paddingHorizontal: 16,
    borderRadius: 8,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  send: {
    borderWidth: 0,
    flex: 1,
  },
  sendLabel: {
    color: '#fff',
    fontWeight: '700',
    fontSize: 16,
  },
});
