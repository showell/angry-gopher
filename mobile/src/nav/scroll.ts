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
