import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { applyTheme, storedTheme, ThemeToggle } from '../src/theme.tsx';

afterEach(() => {
  cleanup();
  window.localStorage.clear();
  delete document.documentElement.dataset.theme;
});

test('NothingStored_ThemeIsLight', () => {
  expect(storedTheme(), 'because light is the default the owner asked for').toBe('light');
});

test('DarkApplied_KeptForTheNextVisit', () => {
  applyTheme('dark');
  expect(storedTheme(), 'because the pick should outlive a reload').toBe('dark');
});

test('ToggleOnLight_SwitchesThePageToDark', async () => {
  applyTheme('light');
  render(<ThemeToggle />);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Dark theme' })); });
  expect(document.documentElement.dataset.theme, 'because the stylesheet reads the theme from the page root').toBe('dark');
  expect(screen.getByRole('button', { name: 'Dark theme' }).getAttribute('aria-pressed'), 'because the button shows which theme is on').toBe('true');
});

test('ToggleOnDark_SwitchesBackToLight', async () => {
  applyTheme('dark');
  render(<ThemeToggle />);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Dark theme' })); });
  expect(storedTheme(), 'because a second press goes back to light').toBe('light');
});
