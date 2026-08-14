export type InlineNode =
  | { kind: 'text'; text: string }
  | { kind: 'br' }
  | { kind: 'em'; children: InlineNode[] }
  | { kind: 'strong'; children: InlineNode[] }
  | { kind: 'code'; text: string }
  | { kind: 'msgref'; id: string; text: string }
  | { kind: 'link'; href: string; external: boolean; children: InlineNode[] };

export type BlockNode =
  | { kind: 'p'; children: InlineNode[]; malformed?: boolean }
  | { kind: 'h'; level: number; children: InlineNode[] }
  | { kind: 'blockquote'; children: BlockNode[] }
  | { kind: 'list'; ordered: boolean; start?: number; items: BlockNode[][] }
  | { kind: 'quote'; text: string }
  | { kind: 'pre'; text: string; lang?: string }
  | { kind: 'img'; src: string; alt: string; width?: number; height?: number }
  | { kind: 'video'; src: string }
  | { kind: 'unknown'; text: string };

export type ContentTree = BlockNode[];
