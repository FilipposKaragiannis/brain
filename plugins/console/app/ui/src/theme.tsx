import { useState } from 'react';

/** The console's two themes. Light is the default; the owner's pick is kept per browser. */
export type Theme = 'light' | 'dark';

const STORAGE_KEY = 'console.theme';

/** The theme this browser picked last, or light. Storage can be blocked, so a failed read is light. */
export function storedTheme(): Theme {
  try {
    return window.localStorage.getItem(STORAGE_KEY) === 'dark' ? 'dark' : 'light';
  } catch {
    return 'light';
  }
}

/** Puts the theme on the page, where the stylesheet reads it, and keeps it for the next visit. */
export function applyTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  try {
    window.localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    // The theme still applies; it is only not remembered.
  }
}

/** The current theme and a switch between the two. */
export function useTheme(): { theme: Theme; toggle: () => void } {
  const [theme, setTheme] = useState<Theme>(() => (document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'));
  const toggle = (): void => {
    const next: Theme = theme === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    setTheme(next);
  };
  return { theme, toggle };
}

/** The page-head button that switches theme. */
export function ThemeToggle() {
  const { theme, toggle } = useTheme();
  return <button type="button" className="button" aria-pressed={theme === 'dark'} onClick={toggle}>Dark theme</button>;
}
