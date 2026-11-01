import { useState } from 'react';

/** The console's two themes. Light is the default; the owner's pick is kept per browser. */
export type Theme = 'light' | 'dark';

const STORAGE_KEY = 'console.theme';

/** The theme toggle's accessible name; it stays put while aria-pressed says whether dark is on. */
export const THEME_TOGGLE_NAME = 'Dark theme';

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

/**
 * The page-head button that switches theme: a small square with a moon while the page is light
 * (it switches to dark) and a sun while it is dark (it switches back). The tooltip names the theme
 * a press brings; the accessible name stays "Dark theme" with aria-pressed saying whether it is on,
 * so a screen reader never hears a name that flips along with the state.
 */
export function ThemeToggle() {
  const { theme, toggle } = useTheme();
  const dark = theme === 'dark';
  return (
    <button type="button" className="icon-button" aria-label={THEME_TOGGLE_NAME} aria-pressed={dark} title={dark ? 'Light theme' : 'Dark theme'} onClick={toggle}>
      {dark ? <SunIcon /> : <MoonIcon />}
    </button>
  );
}

function MoonIcon() {
  return (
    <svg className="icon icon-moon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
    </svg>
  );
}

function SunIcon() {
  return (
    <svg className="icon icon-sun" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
    </svg>
  );
}
