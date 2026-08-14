import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import {
  channelOf,
  dmPartnerName,
  humanizeAgo,
  parseTopicHref,
} from '../api/parse';
import type { RecentEvent } from '../api/types';
import { channelColor, type Palette } from '../theme/colors';

type Props = {
  event: RecentEvent;
  colors: Palette;
  now: number;
  onPress: () => void;
};

export function topicLabel(event: RecentEvent): string {
  if (event.kind === 'doc') {
    return event.title || event.slug || '';
  }
  return event.topic || '';
}

export function canOpenEvent(event: RecentEvent): boolean {
  if (event.kind === 'doc') {
    return !!event.slug;
  }
  return !!event.url && !!parseTopicHref(event.url);
}

export function RecentTile({ event, colors, now, onPress }: Props) {
  const isChat = event.kind === 'chat';
  const isDm = isChat && !!event.dm;
  const channel = isChat ? channelOf(event) : '';
  const partner = isDm ? dmPartnerName(event) : '';
  const initial = (partner || '?').charAt(0).toUpperCase();

  return (
    <Pressable
      testID={'recent-' + (event.kind === 'chat' ? event.topic || event.url : event.slug)}
      accessibilityLabel={topicLabel(event)}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        { opacity: pressed ? 0.7 : 1 },
      ]}>
      <View style={styles.lead}>
        {isDm ? (
          <View
            style={[
              styles.avatar,
              { backgroundColor: colors.accentSoftBg },
            ]}>
            <Text style={[styles.initial, { color: colors.accent }]}>
              {initial}
            </Text>
          </View>
        ) : (
          <View
            style={[
              styles.bar,
              {
                backgroundColor: isChat
                  ? channelColor(channel)
                  : colors.mutedFg,
              },
            ]}
          />
        )}
      </View>
      <View style={styles.body}>
        <View style={styles.top}>
          {isChat && !isDm ? (
            <Text style={[styles.line, { color: colors.bodyMutedFg }]} numberOfLines={1}>
              <Text style={styles.context}>#{channel || 'channel'}</Text>
              <Text style={{ color: colors.mutedFg, fontWeight: '600' }}>
                {'  ·  '}
              </Text>
              <Text style={[styles.topic, { color: colors.fg }]}>
                {event.topic || ''}
              </Text>
            </Text>
          ) : (
            <Text
              style={[styles.title, { color: colors.fg }]}
              numberOfLines={1}>
              {topicLabel(event)}
            </Text>
          )}
          <Text style={[styles.ago, { color: colors.mutedFg }]}>
            {humanizeAgo(event.at, now)}
          </Text>
        </View>
        {isChat && event.excerpt ? (
          <Text
            style={[styles.preview, { color: colors.bodyMutedFg }]}
            numberOfLines={1}>
            {event.who ? (
              <Text style={[styles.who, { color: colors.metaFg }]}>
                {event.who.split(' ')[0] + ': '}
              </Text>
            ) : null}
            {event.excerpt}
          </Text>
        ) : null}
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingTop: 10,
    paddingRight: 8,
    paddingBottom: 10,
    paddingLeft: 12,
    gap: 10,
    borderRadius: 10,
  },
  lead: {
    width: 32,
    alignItems: 'center',
  },
  avatar: {
    width: 32,
    height: 32,
    borderRadius: 16,
    alignItems: 'center',
    justifyContent: 'center',
  },
  initial: {
    fontSize: 13,
    fontWeight: '700',
  },
  bar: {
    width: 8,
    height: 40,
    marginTop: 2,
    borderRadius: 99,
  },
  body: {
    flex: 1,
    minWidth: 0,
  },
  top: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 10,
  },
  line: {
    flex: 1,
    fontSize: 13,
    fontWeight: '600',
  },
  context: {
    fontWeight: '600',
  },
  topic: {
    fontWeight: '600',
    letterSpacing: -0.2,
  },
  title: {
    flex: 1,
    fontSize: 15,
    fontWeight: '600',
    letterSpacing: -0.2,
  },
  ago: {
    fontSize: 12,
    fontWeight: '500',
    fontVariant: ['tabular-nums'],
  },
  preview: {
    marginTop: 2,
    fontSize: 13,
    lineHeight: 17,
  },
  who: {
    fontWeight: '600',
  },
});
