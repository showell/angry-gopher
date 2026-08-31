import type { WireMessage } from '../api/types';
import { appendRecord } from './records';

function msg(partial: Partial<WireMessage> & Pick<WireMessage, 'id' | 'markdown'>): WireMessage {
  return {
    index: 0,
    from: 'Steve',
    at: '2026-08-14T00:00:00Z',
    html: '<p></p>',
    mine: false,
    ...partial,
  };
}

describe('appendRecord', () => {
  it('appends a new bubble and ignores a duplicate id', () => {
    const a = msg({ id: 'yo_1', markdown: 'hi' });
    const once = appendRecord([], a);
    expect(once).toHaveLength(1);
    expect(appendRecord(once, a)).toBe(once);
  });

  it('marks the original bubble when an edit lands', () => {
    const orig = msg({ id: 'yo_1', markdown: 'old' });
    const edit = msg({ id: 'yo_2', markdown: 'Edit of MSG_yo_1\n\nnew' });
    const next = appendRecord(appendRecord([], orig), edit);
    expect(next.find(r => r.id === 'yo_1')?.editedBy).toBe('yo_2');
    expect(next[next.length - 1].id).toBe('yo_2');
  });

  it('does not treat a refer as an edit', () => {
    const orig = msg({ id: 'yo_1', markdown: 'hi' });
    const refer = msg({ id: 'yo_2', markdown: 'See MSG_yo_1 later' });
    const next = appendRecord(appendRecord([], orig), refer);
    expect(next.find(r => r.id === 'yo_1')?.editedBy).toBeUndefined();
  });
});
