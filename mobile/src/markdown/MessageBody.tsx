import React from 'react';
import {
  Image,
  Linking,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import type { Palette } from '../theme/colors';
import { htmlToNodes } from './htmlToNodes';
import type { BlockNode, InlineNode } from './nodes';

type Media = { uri: string; headers?: Record<string, string> };

type Props = {
  html: string;
  colors: Palette;
  resolveMedia: (src: string) => Media;
  onMsgRef: (id: string) => void;
  onCode?: (text: string) => void;
};

function InlineRun({
  nodes,
  colors,
  onMsgRef,
}: {
  nodes: InlineNode[];
  colors: Palette;
  onMsgRef: (id: string) => void;
}) {
  return (
    <Text style={{ color: colors.fg, fontSize: 16, lineHeight: 22 }}>
      {nodes.map((n, i) => {
        if (n.kind === 'text') {
          return <Text key={i}>{n.text}</Text>;
        }
        if (n.kind === 'br') {
          return <Text key={i}>{'\n'}</Text>;
        }
        if (n.kind === 'em') {
          return (
            <Text key={i} style={{ fontStyle: 'italic' }}>
              <InlineRun nodes={n.children} colors={colors} onMsgRef={onMsgRef} />
            </Text>
          );
        }
        if (n.kind === 'strong') {
          return (
            <Text key={i} style={{ fontWeight: '700' }}>
              <InlineRun nodes={n.children} colors={colors} onMsgRef={onMsgRef} />
            </Text>
          );
        }
        if (n.kind === 'code') {
          return (
            <Text
              key={i}
              style={{
                fontFamily: 'Menlo',
                fontSize: 14,
                backgroundColor: colors.codeBg,
                color: colors.codeFg,
              }}>
              {n.text}
            </Text>
          );
        }
        if (n.kind === 'msgref') {
          return (
            <Text
              key={i}
              onPress={() => onMsgRef(n.id)}
              style={{
                fontFamily: 'Menlo',
                fontSize: 14,
                backgroundColor: colors.accentSoftBg,
                color: colors.accent,
              }}>
              {n.text}
            </Text>
          );
        }
        return (
          <Text
            key={i}
            onPress={() => {
              if (n.href) {
                Linking.openURL(n.href).catch(() => {});
              }
            }}
            style={{ color: colors.accent, textDecorationLine: 'underline' }}>
            <InlineRun nodes={n.children} colors={colors} onMsgRef={onMsgRef} />
          </Text>
        );
      })}
    </Text>
  );
}

function Blocks({
  blocks,
  colors,
  resolveMedia,
  onMsgRef,
  onCode,
}: {
  blocks: BlockNode[];
  colors: Palette;
  resolveMedia: (src: string) => Media;
  onMsgRef: (id: string) => void;
  onCode?: (text: string) => void;
}) {
  return (
    <View>
      {blocks.map((b, i) => {
        if (b.kind === 'p') {
          return (
            <View key={i} style={{ marginBottom: 4 }}>
              <InlineRun nodes={b.children} colors={colors} onMsgRef={onMsgRef} />
            </View>
          );
        }
        if (b.kind === 'h') {
          return (
            <View key={i} style={{ marginBottom: 6 }}>
              <Text
                style={{
                  color: colors.fg,
                  fontWeight: '700',
                  fontSize: 22 - b.level * 2,
                }}>
                <InlineRun nodes={b.children} colors={colors} onMsgRef={onMsgRef} />
              </Text>
            </View>
          );
        }
        if (b.kind === 'blockquote') {
          return (
            <View
              key={i}
              style={{
                borderLeftWidth: 3,
                borderLeftColor: colors.quoteBorder,
                paddingLeft: 10,
                marginVertical: 4,
              }}>
              <Blocks
                blocks={b.children}
                colors={colors}
                resolveMedia={resolveMedia}
                onMsgRef={onMsgRef}
                onCode={onCode}
              />
            </View>
          );
        }
        if (b.kind === 'list') {
          return (
            <View key={i} style={{ marginVertical: 4, paddingLeft: 12 }}>
              {b.items.map((item, j) => (
                <View key={j} style={{ flexDirection: 'row', marginBottom: 2 }}>
                  <Text style={{ color: colors.mutedFg, width: 20 }}>
                    {b.ordered ? (b.start || 1) + j + '.' : '•'}
                  </Text>
                  <View style={{ flex: 1 }}>
                    <Blocks
                      blocks={item}
                      colors={colors}
                      resolveMedia={resolveMedia}
                      onMsgRef={onMsgRef}
                      onCode={onCode}
                    />
                  </View>
                </View>
              ))}
            </View>
          );
        }
        if (b.kind === 'quote') {
          return (
            <View
              key={i}
              style={{
                backgroundColor: colors.quoteBg,
                borderLeftWidth: 3,
                borderLeftColor: colors.quoteBorder,
                paddingVertical: 6,
                paddingHorizontal: 10,
                marginVertical: 6,
              }}>
              <Text
                style={{
                  color: colors.bodyMutedFg,
                  fontSize: 15,
                  lineHeight: 21,
                }}>
                {b.text}
              </Text>
            </View>
          );
        }
        if (b.kind === 'pre') {
          return (
            <Pressable
              key={i}
              onPress={() => onCode && onCode(b.text)}
              style={{
                backgroundColor: colors.codeBg,
                padding: 8,
                borderRadius: 4,
                marginVertical: 6,
              }}>
              <Text
                style={{
                  fontFamily: 'Menlo',
                  fontSize: 13,
                  color: colors.codeFg,
                }}>
                {b.text}
              </Text>
            </Pressable>
          );
        }
        if (b.kind === 'img') {
          const src = resolveMedia(b.src);
          return (
            <Image
              key={i}
              source={src}
              style={styles.img}
              resizeMode="contain"
            />
          );
        }
        if (b.kind === 'video') {
          return (
            <Pressable
              key={i}
              onPress={() => Linking.openURL(resolveMedia(b.src).uri)}
              style={{
                backgroundColor: colors.codeBg,
                padding: 12,
                borderRadius: 6,
                marginVertical: 6,
              }}>
              <Text style={{ color: colors.accent }}>Play screencast</Text>
            </Pressable>
          );
        }
        return (
          <Text key={i} style={{ color: colors.mutedFg }}>
            {b.text}
          </Text>
        );
      })}
    </View>
  );
}

export function MessageBody(props: Props) {
  const tree = htmlToNodes(props.html);
  return (
    <Blocks
      blocks={tree}
      colors={props.colors}
      resolveMedia={props.resolveMedia}
      onMsgRef={props.onMsgRef}
      onCode={props.onCode}
    />
  );
}

const styles = StyleSheet.create({
  img: {
    width: '100%',
    maxHeight: 320,
    height: 220,
    marginVertical: 6,
    borderRadius: 6,
  },
});
