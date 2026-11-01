import { cleanup, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { JOB_HOSTS_TITLE, ProjectHeader } from '../src/ProjectHeader.tsx';
import { snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const PROJECT = snapshotAt(TAKEN_AT, 0).project;

/** The value under one label, as the owner reads the row. */
function field(label: string): HTMLElement {
  const term = screen.getByText(label, { selector: 'dt' });
  return term.parentElement!;
}

test('Header_Fields_LabelledInOrder', () => {
  render(<ProjectHeader project={PROJECT} />);
  const labels = screen.getAllByRole('term').map((term) => term.textContent);
  expect(labels, 'because every value says what it is, in the order the owner scans them').toEqual(['Project', 'Repository', 'Tracker', 'Base branch', 'Jobs run on']);
});

test('Header_AnyProject_HasNoPluginFields', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(screen.getByRole('region', { name: 'Project details' }).textContent, 'because the plugins and their versions moved to the Overview footer, so the row stays on which project this is').not.toMatch(/plugin|1\.17\.0|1\.3\.0/i);
});

test('Header_ProjectField_NamesItAndTheTitleShowsTheRoot', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect([field('Project').textContent, field('Project').getAttribute('title')], 'because the name is short and the root says which checkout it is').toEqual(['Projectproject', '/p']);
});

test('ProjectWithARepository_RepositoryFieldLinksIt', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(within(field('Repository')).getByRole('link', { name: 'owner/project' }).getAttribute('href'), 'because the header names where the code lives').toBe('https://github.com/owner/project');
});

test('GithubAdapter_TrackerFieldLinksGithubIssues', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(within(field('Tracker')).getByRole('link', { name: 'GitHub issues' }).getAttribute('href'), 'because the items live on the issues page, and the value says so in words').toBe('https://github.com/owner/project/issues');
});

test('LocalProject_TrackerSaysLocalAndNothingLinks', () => {
  render(<ProjectHeader project={{ ...PROJECT, repo: null, repoUrl: null, trackerUrl: null, adapter: 'local' }} />);
  expect(field('Tracker').textContent, 'because a local tracker has no page, only its name').toBe('Trackerlocal');
  expect(screen.queryAllByRole('link').map((link) => link.textContent), 'because a local project has no repository or tracker page to open').toEqual([]);
});

test('Header_BaseBranch_ShownInMono', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(within(field('Base branch')).getByText('main').className, 'because a branch name reads as code').toBe('mono');
});

test('JobsOnBothHosts_JobsRunOnListsBoth', () => {
  render(<ProjectHeader project={{ ...PROJECT, jobsHost: 'claude', jobHosts: ['claude', 'codex'] }} />);
  expect([field('Jobs run on').textContent, field('Jobs run on').getAttribute('title')], 'because schedules and workers can run on either CLI, and jobs.host alone would hide the other').toEqual(['Jobs run onclaude, codex', JOB_HOSTS_TITLE]);
});

test('NoJobHostsReported_JobsRunOnFallsBackToTheJobsHost', () => {
  render(<ProjectHeader project={{ ...PROJECT, jobsHost: 'codex', jobHosts: [] }} />);
  expect(field('Jobs run on').textContent, 'because the field must still name a host when the daemon lists none').toBe('Jobs run oncodex');
});

test('Header_AnyProject_HasNoSettingsLink', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(screen.queryByRole('link', { name: 'Settings' }), 'because the top bar already has a Settings button, so the row does not repeat it').toBeNull();
});
