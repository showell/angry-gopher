export type Palette = {
  fg: string;
  mutedFg: string;
  softMutedFg: string;
  bodyMutedFg: string;
  metaFg: string;
  accent: string;
  accentHover: string;
  accentSoftBg: string;
  accentSoftHov: string;
  bg: string;
  cardBg: string;
  mineBg: string;
  theirsBg: string;
  quoteBg: string;
  quoteBorder: string;
  codeBg: string;
  codeStrapBg: string;
  codeFg: string;
  border: string;
  softBorder: string;
  dialogBorder: string;
  inputBorder: string;
  searchSelBg: string;
  searchTokFg: string;
  searchMarkBg: string;
  error: string;
  savedFg: string;
  backdrop: string;
  notifyFg: string;
  topBarBg: string;
  topBarBorder: string;
  presenceIdle: string;
  presenceOnline: string;
  selectedRing: string;
};

export const LIGHT: Palette = {
  fg: '#111',
  mutedFg: '#888',
  softMutedFg: '#999',
  bodyMutedFg: '#444',
  metaFg: '#333',
  accent: '#000080',
  accentHover: '#0000a0',
  accentSoftBg: '#eaeaff',
  accentSoftHov: '#d8d8ff',
  bg: '#fff',
  cardBg: '#fafafa',
  mineBg: '#e7e7ff',
  theirsBg: '#f0f0e6',
  quoteBg: '#f6f6fb',
  quoteBorder: '#b9b9e0',
  codeBg: '#f4f4ec',
  codeStrapBg: '#faf9f5',
  codeFg: '#222',
  border: '#ddd',
  softBorder: '#e0e0e0',
  dialogBorder: '#bbb',
  inputBorder: '#e3e3ef',
  searchSelBg: '#eef0ff',
  searchTokFg: '#23235a',
  searchMarkBg: '#ffe680',
  error: '#b00020',
  savedFg: '#1a7a3a',
  backdrop: 'rgba(0,0,0,0.4)',
  notifyFg: '#1a5fb4',
  topBarBg: '#f0ede4',
  topBarBorder: '#c9bfa7',
  presenceIdle: '#3b82f6',
  presenceOnline: '#22c55e',
  selectedRing: '#ffcf3a',
};

export const DARK: Palette = {
  fg: '#e6edf3',
  mutedFg: '#8b949e',
  softMutedFg: '#7d8590',
  bodyMutedFg: '#9aa4ae',
  metaFg: '#b8c0c8',
  accent: '#58a6ff',
  accentHover: '#79b8ff',
  accentSoftBg: '#1f2d4a',
  accentSoftHov: '#28395e',
  bg: '#0d1117',
  cardBg: '#161b22',
  mineBg: '#1c2433',
  theirsBg: '#22221c',
  quoteBg: '#161b22',
  quoteBorder: '#3a3a5c',
  codeBg: '#1a1f26',
  codeStrapBg: '#13171d',
  codeFg: '#e6edf3',
  border: '#30363d',
  softBorder: '#272c33',
  dialogBorder: '#3a3f47',
  inputBorder: '#30363d',
  searchSelBg: '#1f2d4a',
  searchTokFg: '#a8b1c5',
  searchMarkBg: '#6b5210',
  error: '#ff7b72',
  savedFg: '#56d364',
  backdrop: 'rgba(0,0,0,0.6)',
  notifyFg: '#79b8ff',
  topBarBg: '#161b22',
  topBarBorder: '#30363d',
  presenceIdle: '#58a6ff',
  presenceOnline: '#3fb950',
  selectedRing: '#ffcf3a',
};

export const CHANNEL_COLORS = [
  '#3faf8a',
  '#5b8def',
  '#e07a5f',
  '#9b72cf',
  '#e2b340',
  '#4ecdc4',
  '#f28482',
  '#7b8cde',
];

export function channelColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = (h << 5) - h + name.charCodeAt(i);
  }
  return CHANNEL_COLORS[Math.abs(h) % CHANNEL_COLORS.length];
}
