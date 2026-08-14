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
import { sessionOfMsgId } from '../api/parse';
import type { WireMessage } from '../api/types';
import { ComposeBox } from '../components/ComposeBox';
import { MessageBubble, type BubbleRecord } from '../components/MessageBubble';
import {
  editMarkdown,
  editedOriginalId,
  quoteMarkdown,
  referMarkdown,
} from '../compose/actions';
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
  const [records, setRecords] = useState<BubbleRecord[]>([]);
  const [selected, setSelected] = useState('');
  const [draft, setDraft] = useState('');
  const [status, setStatus] = useState('');
  const [statusError, setStatusError] = useState(false);
  const [pending, setPending] = useState(false);
  const [codeText, setCodeText] = useState('');
  const pendingCid = useRef<string | null>(null);
  const pendingTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const listRef = useRef<FlatList<BubbleRecord>>(null);
  const selectedRef = useRef('');
  selectedRef.current = selected;
  const nav = useMemo(() => createNavStack(() => selectedRef.current), []);

  useEffect(() => {
    navigation.setOptions({ title });
  }, [navigation, title]);

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
        setRecords(cur => appendRecord(cur, m));
        if (pendingCid.current && m.cid === pendingCid.current) {
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

  if (!session) {
    return null;
  }

  return (
    <KeyboardAvoidingView
      style={[styles.wrap, { backgroundColor: colors.bg }]}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={88}>
      <FlatList
        ref={listRef}
        data={records}
        keyExtractor={r => r.id}
        contentContainerStyle={styles.list}
        onScrollToIndexFailed={() => {}}
        renderItem={({ item }) => (
          <MessageBubble
            rec={item}
            colors={colors}
            selected={selected === item.id}
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

function appendRecord(cur: BubbleRecord[], m: WireMessage): BubbleRecord[] {
  if (cur.some(r => r.id === m.id)) {
    return cur;
  }
  const next = cur.concat([m]);
  const orig = editedOriginalId(m.markdown);
  if (!orig) {
    return next;
  }
  return next.map(r => (r.id === orig ? { ...r, editedBy: m.id } : r));
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  list: { paddingHorizontal: 12, paddingTop: 12, paddingBottom: 8 },
  codeWrap: { flex: 1, paddingTop: 48 },
});
