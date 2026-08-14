import React, { createContext, useContext, useMemo, useState } from 'react';
import { DARK, LIGHT, type Palette } from './colors';

type Mode = 'light' | 'dark';

type ThemeValue = {
  mode: Mode;
  colors: Palette;
  toggle: () => void;
};

const ThemeContext = createContext<ThemeValue>({
  mode: 'dark',
  colors: DARK,
  toggle: () => {},
});

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setMode] = useState<Mode>('dark');
  const value = useMemo<ThemeValue>(
    () => ({
      mode,
      colors: mode === 'dark' ? DARK : LIGHT,
      toggle: () => setMode(m => (m === 'dark' ? 'light' : 'dark')),
    }),
    [mode],
  );
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeValue {
  return useContext(ThemeContext);
}
