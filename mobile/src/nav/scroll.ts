export const CAUGHT_UP_SLOP = 24;

export type ScrollMetrics = {
  offsetY: number;
  viewportH: number;
  contentH: number;
  slop?: number;
};

export function isCaughtUp(m: ScrollMetrics): boolean {
  const slop = m.slop ?? CAUGHT_UP_SLOP;
  if (m.contentH <= m.viewportH + slop) {
    return true;
  }
  return m.offsetY + m.viewportH >= m.contentH - slop;
}

export type LiveScrollKind = 'own-send' | 'incoming';

/** iMessage / WhatsApp / Telegram / Signal / Slack: a send is a jump
 *  to the live edge. Incoming only follows when the user is caught up. */
export function shouldStickOnEvent(kind: LiveScrollKind, caughtUp: boolean): boolean {
  return kind === 'own-send' || caughtUp;
}
