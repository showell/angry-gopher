import { isCaughtUp } from './scroll';

describe('isCaughtUp', () => {
  it('is true when the last pixel of content is in the viewport', () => {
    expect(
      isCaughtUp({ offsetY: 400, viewportH: 600, contentH: 1000, slop: 1 }),
    ).toBe(true);
  });

  it('is false once the user has scrolled away from the bottom', () => {
    expect(
      isCaughtUp({ offsetY: 100, viewportH: 600, contentH: 1000, slop: 24 }),
    ).toBe(false);
  });

  it('is true when the feed is shorter than the viewport', () => {
    expect(
      isCaughtUp({ offsetY: 0, viewportH: 800, contentH: 200, slop: 24 }),
    ).toBe(true);
  });
});
