import React, { useEffect, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { MessageBody } from '../markdown/MessageBody';
import type { RootStackParamList } from '../navigation/types';
import { useSession } from '../session/Session';
import { useTheme } from '../theme/Theme';

type Props = NativeStackScreenProps<RootStackParamList, 'Doc'>;

export function DocScreen({ route, navigation }: Props) {
  const { slug, title } = route.params;
  const { colors } = useTheme();
  const { session } = useSession();
  const [html, setHtml] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    navigation.setOptions({ title });
  }, [navigation, title]);

  useEffect(() => {
    if (!session) {
      return;
    }
    let cancelled = false;
    session.client
      .docMarkdown(slug)
      .then(md => session.client.renderMarkdown(md))
      .then(rendered => {
        if (!cancelled) {
          setHtml(rendered);
          setLoading(false);
        }
      })
      .catch(e => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : 'Failed to load doc');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [session, slug]);

  return (
    <View style={[styles.wrap, { backgroundColor: colors.bg }]}>
      {loading ? (
        <ActivityIndicator style={{ marginTop: 40 }} color={colors.accent} />
      ) : error ? (
        <Text style={{ color: colors.error, padding: 20 }}>{error}</Text>
      ) : (
        <ScrollView contentContainerStyle={styles.body}>
          <MessageBody
            html={html}
            colors={colors}
            resolveMedia={src => session!.client.mediaUrl(src)}
            onMsgRef={() => {}}
          />
        </ScrollView>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1 },
  body: { padding: 16, paddingBottom: 40 },
});
