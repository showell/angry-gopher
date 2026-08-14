export type NavStack = {
  push: (entry: string) => void;
  back: () => string | null;
  forward: () => string | null;
  canBack: () => boolean;
  canForward: () => boolean;
};

export function createNavStack(currentSelection: () => string): NavStack {
  const entries: string[] = [];
  let pos = -1;

  function pinned(): string {
    return pos >= 0 ? entries[pos] : '';
  }
  function drifted(): boolean {
    const sel = currentSelection();
    return sel.length > 0 && sel !== pinned();
  }

  return {
    push(entry: string) {
      if (entry === pinned()) {
        return;
      }
      entries.length = pos + 1;
      entries.push(entry);
      pos = entries.length - 1;
    },
    back() {
      if (drifted()) {
        return pinned();
      }
      if (pos > 0) {
        pos--;
        return pinned();
      }
      return null;
    },
    forward() {
      if (pos < entries.length - 1) {
        pos++;
        return pinned();
      }
      return null;
    },
    canBack() {
      return pos > 0 || drifted();
    },
    canForward() {
      return pos < entries.length - 1;
    },
  };
}
