import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { ItemLink } from '../src/links.tsx';
import { boardItem, poolWorktree } from './fakeDaemon.tsx';

afterEach(cleanup);

const CLAIMED = { ...poolWorktree('wt-2'), item: 'gh#9', itemUrl: 'https://tracker.example/9' };

test('ItemOnTheBoard_LinksToItsTrackerPage', () => {
  render(<ItemLink id="gh#268" pages={{ items: [boardItem('gh#268', 'Preset retune')], worktrees: [] }} />);
  expect(screen.getByRole('link', { name: 'gh#268' }).getAttribute('href'), 'because an item id opens the tracker page the board gave').toBe('https://github.com/owner/project/issues/268');
});

test('ItemNotOnTheBoard_FallsBackToTheWorktreeUrl', () => {
  render(<ItemLink id="gh#9" pages={{ items: [], worktrees: [CLAIMED] }} />);
  expect(screen.getByRole('link', { name: 'gh#9' }).getAttribute('href'), 'because a claimed worktree knows its item page before the board lists it').toBe('https://tracker.example/9');
});

test('ItemLink_OpensInANewTab', () => {
  render(<ItemLink id="gh#9" pages={{ items: [], worktrees: [CLAIMED] }} />);
  expect(screen.getByRole('link', { name: 'gh#9' }).getAttribute('target'), 'because the tracker must not replace the console').toBe('_blank');
});

test('NoPageKnown_PlainText', () => {
  render(<ItemLink id="local:task/7" pages={{ items: [], worktrees: [] }} />);
  expect(screen.queryByRole('link'), 'because a link with nowhere to go is a dead end').toBeNull();
});

test('ItemUrlWithJavascriptScheme_PlainText', () => {
  const hostile = { ...boardItem('gh#5', 'Hostile'), url: 'javascript:alert(document.cookie)' };
  render(<ItemLink id="gh#5" pages={{ items: [hostile], worktrees: [] }} />);
  expect(screen.queryByRole('link'), 'because a tracker URL that is not http or https must never become something to click').toBeNull();
});
