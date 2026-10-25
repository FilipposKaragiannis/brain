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
  expect(screen.queryByRole('link'), 'because a local project has no page to open').toBeNull();
});

test('Header_SaysTheJobsHost', () => {
  render(<ProjectHeader project={{ ...PROJECT, jobsHost: 'codex' }} />);
  expect(screen.queryByText('jobs on codex'), 'because which CLI runs the jobs changes what the agents can do').not.toBeNull();
});
