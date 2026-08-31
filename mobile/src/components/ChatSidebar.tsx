import React, { useMemo, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import type { Sidebar, SidebarItem } from '../api/types';
import type { Palette } from '../theme/colors';

const TOPIC_RE = /^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$/;

type Props = {
  data: Sidebar;
  colors: Palette;
  onSelectConversation: (item: SidebarItem) => void;
  onSelectSession: (item: SidebarItem) => void;
  onAddTopic: (name: string) => Promise<void> | void;
};

export function ChatSidebar({
  data,
  colors,
  onSelectConversation,
  onSelectSession,
  onAddTopic,
}: Props) {
  const [topic, setTopic] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    const name = topic.trim();
    if (!TOPIC_RE.test(name)) {
      setErr('Letters, digits, and hyphens only.');
      return;
    }
    setErr('');
    setBusy(true);
    try {
      await onAddTopic(name);
      setTopic('');
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not add topic');
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.rail} contentContainerStyle={styles.pad}>
      <Section
        title="Conversations"
        section="conversations"
        colors={colors}
        items={data.conversations}
        renderItem={item => (
          <Row
            key={item.id}
            item={item}
            colors={colors}
            presence={item.id.indexOf('uid:') === 0}
            onPress={() => onSelectConversation(item)}
          />
        )}
      />
      <Section
        title="Pinned Sessions"
        section="pinned"
        colors={colors}
        items={data.pinned_sessions}
        empty={{ text: 'Drag a session here to pin it' }}
        renderItem={item => (
          <Row
            key={item.id}
            item={item}
            colors={colors}
            onPress={() => onSelectSession(item)}
          />
        )}
      />
      <Section
        title="Sessions"
        section="sessions"
        colors={colors}
        items={data.sessions}
        empty={{ text: 'No sessions yet' }}
        renderItem={item => (
          <Row
            key={item.id}
            item={item}
            colors={colors}
            onPress={() => onSelectSession(item)}
          />
        )}
      />
      <View style={styles.add}>
        <TextInput
          testID="add-topic-input"
          value={topic}
          onChangeText={setTopic}
          placeholder="new-topic"
          placeholderTextColor={colors.mutedFg}
          autoCapitalize="none"
          autoCorrect={false}
          maxLength={80}
          editable={!busy}
          style={[
            styles.addInput,
            {
              color: colors.fg,
              borderColor: colors.border,
              backgroundColor: colors.bg,
            },
          ]}
        />
        <Pressable
          testID="add-topic-submit"
          onPress={submit}
          disabled={busy}
          style={[styles.addBtn, { borderColor: colors.border }]}>
          <Text style={{ color: colors.fg, fontSize: 12 }}>Add Topic</Text>
        </Pressable>
      </View>
      {err ? <Text style={{ color: colors.error, fontSize: 11 }}>{err}</Text> : null}
    </ScrollView>
  );
}

function Section({
  title,
  section,
  colors,
  items,
  empty,
  renderItem,
}: {
  title: string;
  section: string;
  colors: Palette;
  items: SidebarItem[];
  empty?: { text: string };
  renderItem: (item: SidebarItem) => React.ReactNode;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const body = useMemo(() => {
    if (items && items.length) {
      return items.map(renderItem);
    }
    if (empty) {
      return (
        <Text style={[styles.hint, { color: colors.mutedFg }]}>{empty.text}</Text>
      );
    }
    return null;
  }, [items, empty, colors.mutedFg, renderItem]);

  return (
    <View
      style={styles.section}
      testID={'sidebar-' + section}
      accessibilityLabel={section}>
      <Pressable onPress={() => setCollapsed(c => !c)} style={styles.title}>
        <Text style={[styles.caret, { color: colors.mutedFg }]}>
          {collapsed ? '▸' : '▾'}
        </Text>
        <Text style={[styles.titleText, { color: colors.mutedFg }]}>{title}</Text>
      </Pressable>
      {collapsed ? null : <View>{body}</View>}
    </View>
  );
}

function Row({
  item,
  colors,
  presence,
  onPress,
}: {
  item: SidebarItem;
  colors: Palette;
  presence?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      style={[
        styles.row,
        item.active
          ? { backgroundColor: colors.accent }
          : undefined,
      ]}>
      {presence ? (
        <View
          style={[
            styles.dot,
            {
              backgroundColor: item.online ? colors.presenceOnline : 'transparent',
              borderColor: item.online ? colors.presenceOnline : colors.presenceIdle,
            },
          ]}
        />
      ) : null}
      <Text
        numberOfLines={1}
        style={{
          color: item.active ? colors.bg : colors.accent,
          fontWeight: item.active ? '700' : '400',
          fontSize: 13,
          flex: 1,
        }}>
        {item.label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  rail: { flex: 1 },
  pad: { paddingRight: 14, paddingBottom: 24 },
  section: { marginBottom: 18 },
  title: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    marginBottom: 6,
  },
  caret: { fontSize: 9, width: 10 },
  titleText: {
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 0.8,
    textTransform: 'uppercase',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 4,
    paddingHorizontal: 8,
    borderRadius: 3,
    gap: 6,
  },
  dot: {
    width: 9,
    height: 9,
    borderRadius: 5,
    borderWidth: 1.5,
  },
  hint: {
    fontSize: 11,
    fontStyle: 'italic',
    paddingVertical: 4,
    paddingHorizontal: 8,
  },
  add: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 4,
    marginTop: 8,
  },
  addInput: {
    flex: 1,
    minWidth: 80,
    paddingVertical: 6,
    paddingHorizontal: 8,
    fontSize: 12,
    borderWidth: 1,
    borderRadius: 3,
  },
  addBtn: {
    paddingVertical: 6,
    paddingHorizontal: 8,
    borderWidth: 1,
    borderRadius: 3,
    justifyContent: 'center',
  },
});
