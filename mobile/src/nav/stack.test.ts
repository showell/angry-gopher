import { createNavStack } from './stack';

describe('NavStack', () => {
  it('walks back and forward and ignores a duplicate push', () => {
    let sel = '';
    const s = createNavStack(() => sel);
    s.push('a');
    s.push('a');
    s.push('b');
    expect(s.back()).toBe('a');
    expect(s.forward()).toBe('b');
    expect(s.forward()).toBeNull();
  });

  it('returns to the pinned entry first when selection has drifted', () => {
    let sel = 'a';
    const s = createNavStack(() => sel);
    s.push('a');
    s.push('b');
    sel = 'c';
    expect(s.canBack()).toBe(true);
    expect(s.back()).toBe('b');
    sel = 'b';
    expect(s.back()).toBe('a');
    sel = 'a';
    expect(s.back()).toBeNull();
  });
});
