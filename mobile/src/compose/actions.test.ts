import {
  EDIT_RE,
  composeMarkers,
  editMarkdown,
  editedOriginalId,
  pickQuoteFence,
  quoteMarkdown,
  referMarkdown,
} from './actions';

describe('pickQuoteFence', () => {
  it('uses three tildes when the body has no fence', () => {
    expect(pickQuoteFence('hello')).toBe('~~~');
  });

  it('grows one longer than the longest leading tilde run', () => {
    expect(pickQuoteFence('~~~\nquoted\n~~~')).toBe('~~~~');
    expect(pickQuoteFence('~~~~ quote\ninner\n~~~~')).toBe('~~~~~');
  });
});

describe('compose inserts', () => {
  it('quotes with I/you and a growing fence', () => {
    expect(
      quoteMarkdown({ id: 'yo_1', markdown: 'hi', mine: false }),
    ).toBe('In MSG_yo_1 you said:\n~~~ quote\nhi\n~~~\n\n');
    expect(
      quoteMarkdown({ id: 'yo_1', markdown: 'hi', mine: true }),
    ).toBe('In MSG_yo_1 I said:\n~~~ quote\nhi\n~~~\n\n');
  });

  it('refers with a trailing space', () => {
    expect(referMarkdown('yo_1')).toBe('See MSG_yo_1 ');
  });

  it('edits as a new message with the caret after the blank line', () => {
    const e = editMarkdown({ id: 'yo_1', markdown: 'old body', mine: true });
    expect(e.text).toBe('Edit of MSG_yo_1\n\nold body');
    expect(e.caretAt).toBe('Edit of MSG_yo_1\n\n'.length);
    expect(e.text.slice(0, e.caretAt)).toBe('Edit of MSG_yo_1\n\n');
  });

  it('detects an edit backlink the way chat.js does', () => {
    expect(editedOriginalId('Edit of MSG_yo_1\n\nnew')).toBe('yo_1');
    expect(editedOriginalId('See MSG_yo_1')).toBeNull();
    expect(EDIT_RE.test('Edit of MSG_not-an-id')).toBe(false);
  });
});

describe('composeMarkers', () => {
  it('flags quote, refer, and edit independently', () => {
    expect(composeMarkers(quoteMarkdown({ id: 'yo_1', markdown: 'hi', mine: false }))).toEqual([
      'quote',
    ]);
    expect(composeMarkers(referMarkdown('yo_1'))).toEqual(['refer']);
    expect(composeMarkers(editMarkdown({ id: 'yo_1', markdown: 'old', mine: true }).text)).toEqual([
      'edit',
    ]);
    expect(
      composeMarkers(referMarkdown('yo_1') + quoteMarkdown({ id: 'yo_2', markdown: 'x', mine: true })),
    ).toEqual(['quote', 'refer']);
  });
});
