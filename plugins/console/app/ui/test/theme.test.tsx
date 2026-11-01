import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { applyTheme, storedTheme, THEME_TOGGLE_NAME, ThemeToggle } from '../src/theme.tsx';

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
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: THEME_TOGGLE_NAME })); });
  expect(document.documentElement.dataset.theme, 'because the stylesheet reads the theme from the page root').toBe('dark');
  expect(screen.getByRole('button', { name: THEME_TOGGLE_NAME }).getAttribute('aria-pressed'), 'because the button shows which theme is on').toBe('true');
});

test('ToggleOnDark_SwitchesBackToLight', async () => {
  applyTheme('dark');
  render(<ThemeToggle />);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: THEME_TOGGLE_NAME })); });
  expect(storedTheme(), 'because a second press goes back to light').toBe('light');
});

test('LightPage_ToggleIsAnIconWithAnAccessibleName', () => {
  applyTheme('light');
  render(<ThemeToggle />);
  const toggle = screen.getByRole('button', { name: 'Dark theme' });
  expect([toggle.textContent, toggle.getAttribute('title'), toggle.getAttribute('aria-pressed'), toggle.querySelector('svg.icon-moon') !== null], 'because the small button shows a moon instead of words, and a screen reader still hears what it does').toEqual(['', 'Dark theme', 'false', true]);
});

test('DarkPage_ToggleShowsASunAndOffersLight', () => {
  applyTheme('dark');
  render(<ThemeToggle />);
  const toggle = screen.getByRole('button', { name: 'Dark theme' });
  expect([toggle.getAttribute('title'), toggle.getAttribute('aria-pressed'), toggle.querySelector('svg.icon-sun') !== null], 'because on a dark page the sun says a press brings the light theme back').toEqual(['Light theme', 'true', true]);
});
