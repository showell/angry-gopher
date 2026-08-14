import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { formatLocalTime } from '../api/parse';
import type { WireMessage } from '../api/types';
import { MessageBody } from '../markdown/MessageBody';
import type { Palette } from '../theme/colors';

export type BubbleRecord = WireMessage & {
  saved?: boolean;
  editedBy?: string;
};

type Props = {
  rec: BubbleRecord;
  colors: Palette;
  selected: boolean;
  resolveMedia: (src: string) => { uri: string; headers?: Record<string, string> };
  onSelect: () => void;
  onQuote: () => void;
  onRefer: () => void;
  onEdit: () => void;
  onSave: () => void;
  onMsgRef: (id: string) => void;
  onCode?: (text: string) => void;
};

function Action({
  label,
  onPress,
  color,
  saved,
}: {
  label: string;
  onPress: () => void;
  color: string;
  saved?: boolean;
}) {
  return (
    <Pressable onPress={onPress} hitSlop={8}>
      <Text
        style={{
          fontSize: 12,
          color,
          textDecorationLine: saved ? 'none' : 'underline',
          fontWeight: saved ? '700' : '400',
        }}>
        {label}
      </Text>
    </Pressable>
  );
}

export function MessageBubble({
  rec,
  colors,
  selected,
  resolveMedia,
  onSelect,
  onQuote,
  onRefer,
  onEdit,
  onSave,
  onMsgRef,
  onCode,
}: Props) {
  return (
    <Pressable
      onPress={onSelect}
      style={[
        styles.bubble,
        {
          backgroundColor: rec.mine ? colors.mineBg : colors.theirsBg,
          alignSelf: rec.mine ? 'flex-end' : 'flex-start',
          shadowColor: selected ? colors.selectedRing : 'transparent',
          shadowOpacity: selected ? 1 : 0,
          shadowRadius: selected ? 0 : 0,
          borderWidth: selected ? 2 : 0,
          borderColor: selected ? colors.selectedRing : 'transparent',
        },
      ]}>
      <View style={styles.meta}>
        <Text style={{ color: colors.mutedFg, fontSize: 11 }}>
          {'#' + (rec.index + 1) + ' ' + rec.from + ' · ' + formatLocalTime(rec.at)}
        </Text>
        <View style={styles.actions}>
          <Action label="quote" onPress={onQuote} color={colors.mutedFg} />
          <Action label="refer" onPress={onRefer} color={colors.mutedFg} />
          <Action label="edit" onPress={onEdit} color={colors.mutedFg} />
          <Action
            label={rec.saved ? '✓ saved' : 'save'}
            onPress={onSave}
            color={rec.saved ? colors.savedFg : colors.mutedFg}
            saved={rec.saved}
          />
        </View>
      </View>
      {rec.editedBy ? (
        <View style={{ marginBottom: 6 }}>
          <Text style={{ color: colors.mutedFg, fontSize: 12 }}>
            {'Edited in '}
            <Text
              onPress={() => onMsgRef(rec.editedBy!)}
              style={{
                fontFamily: 'Menlo',
                color: colors.accent,
                backgroundColor: colors.accentSoftBg,
              }}>
              {'MSG_' + rec.editedBy}
            </Text>
          </Text>
          <Text style={{ color: colors.softMutedFg, fontSize: 11, marginTop: 4 }}>
            original
          </Text>
          <Text
            style={{
              color: colors.softMutedFg,
              fontSize: 11,
              borderLeftWidth: 3,
              borderLeftColor: colors.border,
              paddingLeft: 8,
              marginTop: 2,
            }}>
            {rec.markdown}
          </Text>
        </View>
      ) : (
        <MessageBody
          html={rec.html}
          colors={colors}
          resolveMedia={resolveMedia}
          onMsgRef={onMsgRef}
          onCode={onCode}
        />
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  bubble: {
    marginBottom: 12,
    paddingVertical: 8,
    paddingHorizontal: 10,
    borderRadius: 8,
    maxWidth: '88%',
  },
  meta: {
    marginBottom: 4,
    gap: 4,
  },
  actions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 12,
    marginTop: 2,
  },
});
