export type QuoteRecord = {
  id: string;
  markdown: string;
  mine: boolean;
};

export const EDIT_RE = /^Edit of MSG_([A-Za-z0-9-]+_[0-9]+)\b/;

export function pickQuoteFence(md: string): string {
  const runs = md.match(/^~{3,}/gm);
  let max = 2;
  if (runs) {
    for (let i = 0; i < runs.length; i++) {
      if (runs[i].length > max) {
        max = runs[i].length;
      }
    }
  }
  return '~'.repeat(max + 1);
}

export function quoteMarkdown(rec: QuoteRecord): string {
  const fence = pickQuoteFence(rec.markdown);
  return (
    'In MSG_' +
    rec.id +
    ' ' +
    (rec.mine ? 'I said' : 'you said') +
    ':\n' +
    fence +
    ' quote\n' +
    rec.markdown +
    '\n' +
    fence +
    '\n\n'
  );
}

export function referMarkdown(id: string): string {
  return 'See MSG_' + id + ' ';
}

export function editPrefix(id: string): string {
  return 'Edit of MSG_' + id + '\n\n';
}

export function editMarkdown(rec: QuoteRecord): { text: string; caretAt: number } {
  const prefix = editPrefix(rec.id);
  return { text: prefix + rec.markdown, caretAt: prefix.length };
}

export function editedOriginalId(markdown: string): string | null {
  const m = markdown.match(EDIT_RE);
  return m ? m[1] : null;
}

export function composeMarkers(draft: string): Array<'quote' | 'refer' | 'edit'> {
  const out: Array<'quote' | 'refer' | 'edit'> = [];
  if (/In MSG_\S+ (I|you) said:/.test(draft)) {
    out.push('quote');
  }
  if (/\bSee MSG_/.test(draft)) {
    out.push('refer');
  }
  if (EDIT_RE.test(draft)) {
    out.push('edit');
  }
  return out;
}
