import type { WireMessage } from '../api/types';
import type { BubbleRecord } from '../components/MessageBubble';
import { editedOriginalId } from './actions';

export function appendRecord(cur: BubbleRecord[], m: WireMessage): BubbleRecord[] {
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
