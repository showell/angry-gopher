import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { launchImageLibrary } from 'react-native-image-picker';
import {
  applySidebarEvent,
  convBaseFromUrl,
  convKeyFromPath,
  emptySidebar,
  parseTopicHref,
  sessionOfMsgId,
  topicPeerLabel,
} from '../api/parse';
import type { Sidebar, SidebarItem } from '../api/types';
import { ChatSidebar } from '../components/ChatSidebar';
import { ComposeBox } from '../components/ComposeBox';
import { MessageBubble, type BubbleRecord } from '../components/MessageBubble';
import { editMarkdown, quoteMarkdown, referMarkdown } from '../compose/actions';
import { appendRecord } from '../compose/records';
import { isCaughtUp, shouldStickOnEvent } from '../nav/scroll';
import { createNavStack } from '../nav/stack';
import type { RootStackParamList } from '../navigation/types';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

type Props = NativeStackScreenProps<RootStackParamList, 'Topic'>;

function newCid(): string {
  return Date.now() + '-' + Math.random().toString(16).slice(2);
}

export function TopicScreen({ route, navigation }: Props) {
  const { convBase, sid, title, focusId } = route.params;
  const { colors } = useTheme();
  const { session } = useSession();
  const peer =
    topicPeerLabel(convBase, session?.conversations || []) || route.params.peer || '';
  const [records, setRecords] = useState<BubbleRecord[]>([]);
  const [selected, setSelected] = useState('');
  const [draft, setDraft] = useState('');
  const [status, setStatus] = useState('');
  const [statusError, setStatusError] = useState(false);
  const [pending, setPending] = useState(false);
  const [codeText, setCodeText] = useState('');
  const [rail, setRail] = useState(false);
  const [side, setSide] = useState<Sidebar>(emptySidebar());
  const pendingCid = useRef<string | null>(null);
  const pendingTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const listRef = useRef<FlatList<BubbleRecord>>(null);
  const selectedRef = useRef('');
  selectedRef.current = selected;
  const nav = useMemo(() => createNavStack(() => selectedRef.current), []);
  const caughtUpRef = useRef(true);
  const progScroll = useRef(false);
  const [showJump, setShowJump] = useState(false);

  function markCaughtUp(next: boolean) {
    caughtUpRef.current = next;
    setShowJump(!next);
  }

  function stickToBottom(animated: boolean) {
    progScroll.current = true;
    markCaughtUp(true);
    requestAnimationFrame(() => {
      listRef.current?.scrollToEnd({ animated });
      setTimeout(() => {
        progScroll.current = false;
      }, 200);
    });
  }

  useEffect(() => {
    navigation.setOptions({
      title: peer || title,
      headerTitle: () => (
        <View style={styles.headerTitle} testID="topic-header">
          {peer ? (
            <Text
              testID="topic-peer"
              numberOfLines={1}
              style={[styles.headerPeer, { color: colors.fg }]}>
              {peer}
            </Text>
          ) : null}
          <Text
            testID="topic-heading"
            numberOfLines={1}
            style={[
              styles.headerTopic,
              { color: peer ? colors.mutedFg : colors.fg, fontSize: peer ? 12 : 17 },
            ]}>
            {title}
          </Text>
        </View>
      ),
      headerRight: () => (
        <Pressable
          testID="topic-sidebar"
          onPress={() => setRail(true)}
          hitSlop={8}
          style={{ marginRight: 4 }}>
          <Text style={{ color: colors.accent, fontSize: 18, fontWeight: '700' }}>☰</Text>
        </Pressable>
      ),
    });
  }, [navigation, title, peer, colors.accent, colors.fg, colors.mutedFg]);

  useEffect(() => {
    if (!session) {
      return;
    }
    session.client
      .sidebar(convBase + '/' + encodeURIComponent(sid))
      .then(setSide)
      .catch(() => {});
    return session.client.streamSidebar(evt => {
      setSide(cur => applySidebarEvent(cur, evt, convKeyFromPath(convBase)));
    });
  }, [session, convBase, sid]);

  useEffect(() => {
    if (!session) {
      return;
    }
    let stop: (() => void) | undefined;
    let cancelled = false;
    session.client
      .saved(convBase, sid)
      .then(ids => {
        if (cancelled) {
          return;
        }
        const set = new Set(ids);
        setRecords(cur => cur.map(r => ({ ...r, saved: set.has(r.id) })));
      })
      .catch(() => {});
    stop = session.client.streamTopic(convBase, sid, 0, {
      onMessage(m) {
        if (cancelled) {
          return;
        }
        const own = !!(pendingCid.current && m.cid === pendingCid.current);
        const stick = shouldStickOnEvent(own ? 'own-send' : 'incoming', caughtUpRef.current);
        setRecords(cur => {
          const next = appendRecord(cur, m);
          if (stick && next.length) {
            setSelected(next[next.length - 1].id);
          }
          return next;
        });
        if (stick) {
          stickToBottom(true);
        }
        if (own) {
          clearPending(true);
        }
      },
    });
    return () => {
      cancelled = true;
      if (stop) {
        stop();
      }
    };
  }, [session, convBase, sid]);

  useEffect(() => {
    if (focusId && records.some(r => r.id === focusId)) {
      focusMessage(focusId);
    }
  }, [focusId, records.length]);

  function clearPending(ack: boolean) {
    if (pendingTimer.current) {
      clearTimeout(pendingTimer.current);
      pendingTimer.current = null;
    }
    pendingCid.current = null;
    setPending(false);
    if (ack) {
      setDraft('');
      setStatus('');
      setStatusError(false);
    }
  }

  function hostDown() {
    if (!pendingCid.current) {
      return;
    }
    clearPending(false);
    setStatusError(true);
    setStatus('The host may be down. Please retry your send.');
  }

  function focusMessage(id: string) {
    setSelected(id);
    nav.push(id);
    const idx = records.findIndex(r => r.id === id);
    if (idx >= 0) {
      listRef.current?.scrollToIndex({ index: idx, viewPosition: 0.5 });
    }
  }

  function jumpRef(id: string) {
    const sessionOf = sessionOfMsgId(id);
    if (sessionOf === sid) {
      focusMessage(id);
      return;
    }
    navigation.push('Topic', {
      convBase,
      sid: sessionOf || sid,
      title: sessionOf || sid,
      focusId: id,
    });
  }

  function insert(text: string) {
    if (pending) {
      return;
    }
    setDraft(d => d + text);
  }

  async function send(text: string) {
    if (!session || pending || !text.trim()) {
      return;
    }
    const cid = newCid();
    pendingCid.current = cid;
    setPending(true);
    setStatusError(false);
    setStatus('Sending…');
    stickToBottom(true);
    pendingTimer.current = setTimeout(hostDown, 3000);
    try {
      await session.client.send(convBase, sid, text, cid);
    } catch (e) {
      clearPending(false);
      setStatusError(true);
      setStatus(e instanceof Error ? e.message : 'Send failed');
    }
  }

  async function upload() {
    if (!session || pending) {
      return;
    }
    const picked = await launchImageLibrary({
      mediaType: 'mixed',
      selectionLimit: 1,
    });
    const asset = picked.assets && picked.assets[0];
    if (!asset || !asset.uri) {
      return;
    }
    const isVideo = (asset.type || '').indexOf('video/') === 0;
    setStatus(isVideo ? 'Uploading screencast…' : 'Uploading image…');
    setStatusError(false);
    try {
      const d = await session.client.upload(convBase, sid, {
        uri: asset.uri,
        name: asset.fileName || (isVideo ? 'clip.mp4' : 'image.jpg'),
        type: asset.type || (isVideo ? 'video/mp4' : 'image/jpeg'),
      });
      if (d.kind === 'video') {
        insert('<video src="' + d.url + '"></video>');
      } else {
        const alt = (d.name || 'image').replace(/["<>\r\n]/g, '');
        insert('<img src="' + d.url + '" alt="' + alt + '">');
      }
      setStatus('');
    } catch (e) {
      setStatusError(true);
      setStatus(e instanceof Error ? e.message : 'Upload failed');
    }
  }

  async function save(rec: BubbleRecord) {
    if (!session) {
      return;
    }
    try {
      await session.client.saveToReadingList({
        conv:
          convBase.indexOf('/chat/c/') === 0
            ? convBase.slice('/chat/c/'.length)
            : convBase.indexOf('/channel/') === 0
              ? convBase.slice('/channel/'.length)
              : convBase,
        sid,
        id: rec.id,
        from: rec.from,
        at: rec.at,
        body: rec.markdown,
        note: 'read later',
      });
      setRecords(cur => cur.map(r => (r.id === rec.id ? { ...r, saved: true } : r)));
    } catch {
      Alert.alert('Save failed');
    }
  }

  function openSession(item: SidebarItem) {
    const ref = parseTopicHref(item.url);
    const base = ref ? ref.convBase : convBaseFromUrl(item.url) || convBase;
    const nextSid = ref ? ref.sid : item.id;
    setRail(false);
    if (base === convBase && nextSid === sid) {
      return;
    }
    navigation.replace('Topic', { convBase: base, sid: nextSid, title: item.label });
  }

  if (!session) {
    return null;
  }

  return (
    <KeyboardAvoidingView
      style={[styles.wrap, { backgroundColor: colors.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={88}>
      <View style={styles.feed}>
      <FlatList
        ref={listRef}
        testID="topic-feed"
        data={records}
        keyExtractor={r => r.id}
        contentContainerStyle={styles.list}
        onScrollToIndexFailed={() => {}}
        scrollEventThrottle={16}
        onScroll={e => {
          if (progScroll.current) {
            return;
          }
          const n = e.nativeEvent;
          markCaughtUp(
            isCaughtUp({
              offsetY: n.contentOffset.y,
              viewportH: n.layoutMeasurement.height,
              contentH: n.contentSize.height,
            }),
          );
        }}
        onScrollEndDrag={e => {
          if (progScroll.current) {
            return;
          }
          const n = e.nativeEvent;
          markCaughtUp(
            isCaughtUp({
              offsetY: n.contentOffset.y,
              viewportH: n.layoutMeasurement.height,
              contentH: n.contentSize.height,
            }),
          );
        }}
        onContentSizeChange={() => {
          if (caughtUpRef.current) {
            stickToBottom(false);
          }
        }}
        renderItem={({ item, index }) => (
          <MessageBubble
            rec={item}
            colors={colors}
            selected={selected === item.id}
            exposeActions={index === records.length - 1}
            resolveMedia={src => session.client.mediaUrl(src)}
            onSelect={() => {
              setSelected(item.id);
              nav.push(item.id);
            }}
            onQuote={() => insert(quoteMarkdown(item))}
            onRefer={() => insert(referMarkdown(item.id))}
            onEdit={() => {
              const e = editMarkdown(item);
              setDraft(e.text);
            }}
            onSave={() => {
              save(item).catch(() => {});
            }}
            onMsgRef={jumpRef}
            onCode={setCodeText}
          />
        )}
      />
      {showJump ? (
        <Pressable
          testID="jump-bottom"
          onPress={() => {
            if (records.length) {
              setSelected(records[records.length - 1].id);
            }
            stickToBottom(true);
          }}
          style={[
            styles.jump,
            { backgroundColor: colors.accent },
          ]}>
          <Text style={styles.jumpLabel}>↓</Text>
        </Pressable>
      ) : null}
      </View>
      <ComposeBox
        colors={colors}
        disabled={pending}
        status={status}
        statusError={statusError}
        sending={pending}
        draft={draft}
        onDraft={setDraft}
        onSend={send}
        onUpload={() => {
          upload().catch(() => {});
        }}
      />
      <Modal visible={rail} animationType="slide" onRequestClose={() => setRail(false)}>
        <View style={[styles.railWrap, { backgroundColor: colors.bg }]}>
          <Pressable onPress={() => setRail(false)} style={{ padding: 16 }}>
            <Text style={{ color: colors.accent, fontWeight: '600' }}>Close</Text>
          </Pressable>
          <ChatSidebar
            data={side}
            colors={colors}
            onSelectConversation={item => {
              session.client
                .sidebar(item.url)
                .then(next => {
                  setSide(next);
                  const land = next.sessions.find(s => s.active) || next.sessions[0] || next.pinned_sessions[0];
                  if (land) {
                    openSession(land);
                  }
                })
                .catch(() => {});
            }}
            onSelectSession={openSession}
            onAddTopic={async name => {
              const j = await session.client.addTopic(convBase, name);
              openSession({
                id: j.sid,
                label: j.sid,
                url: convBase + '/' + j.sid,
              });
            }}
          />
        </View>
      </Modal>
      <Modal visible={!!codeText} animationType="slide" onRequestClose={() => setCodeText('')}>
        <View style={[styles.codeWrap, { backgroundColor: colors.bg }]}>
          <Pressable onPress={() => setCodeText('')} style={{ padding: 16 }}>
            <Text style={{ color: colors.accent, fontWeight: '600' }}>Close</Text>
          </Pressable>
          <Text
            selectable
            style={{
              fontFamily: 'Menlo',
              color: colors.codeFg,
              paddingHorizontal: 16,
            }}>
            {codeText}
          </Text>
        </View>
      </Modal>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  feed: { flex: 1 },
  headerTitle: { alignItems: 'center', maxWidth: 220 },
  headerPeer: { fontSize: 16, fontWeight: '700' },
  headerTopic: { fontWeight: '500' },
  list: { paddingHorizontal: 12, paddingTop: 12, paddingBottom: 8 },
  jump: {
    position: 'absolute',
    right: 16,
    bottom: 12,
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
  },
  jumpLabel: { color: '#fff', fontSize: 22, fontWeight: '700', lineHeight: 24 },
  codeWrap: { flex: 1, paddingTop: 48 },
  railWrap: { flex: 1, paddingTop: 48, paddingLeft: 16 },
});
