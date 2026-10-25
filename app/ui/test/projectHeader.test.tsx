import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { ProjectHeader } from '../src/ProjectHeader.tsx';
import { snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const PROJECT = snapshotAt(TAKEN_AT, 0).project;

test('ProjectWithARepository_LinksIt', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(screen.getByRole('link', { name: 'owner/project' }).getAttribute('href'), 'because the header names where the code lives').toBe('https://github.com/owner/project');
});

test('ProjectWithATracker_LinksIt', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(screen.getByRole('link', { name: 'tracker' }).getAttribute('href'), 'because the items live there').toBe('https://github.com/owner/project/issues');
});

test('LocalProject_NoRepositoryLink', () => {
  render(<ProjectHeader project={{ ...PROJECT, repo: null, repoUrl: null, trackerUrl: null, adapter: 'local' }} />);
  expect(screen.queryAllByRole('link').map((link) => link.textContent), 'because a local project has no repository or tracker page to open, only the Settings link').toEqual(['Settings']);
});

test('Header_SaysTheJobsHost', () => {
  render(<ProjectHeader project={{ ...PROJECT, jobsHost: 'codex' }} />);
  expect(screen.getByLabelText('Project details').textContent, 'because which CLI runs the jobs changes what the agents can do').toMatch(/codex/);
});

test('Header_AnyProject_LinksToSettings', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(screen.getByRole('link', { name: 'Settings' }).getAttribute('href'), 'because projects are now added and removed there, not only at start').toBe('#/settings');
});
