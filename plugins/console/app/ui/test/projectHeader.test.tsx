import { cleanup, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { ProjectHeader } from '../src/ProjectHeader.tsx';
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
  expect(labels, 'because every value says what it is, in the order the owner scans them').toEqual(['Project', 'Repository', 'Tracker', 'Base branch', 'Flow plugin', 'Jobs run on']);
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

test('LocalProject_TrackerSaysLocalAndOnlySettingsLinks', () => {
  render(<ProjectHeader project={{ ...PROJECT, repo: null, repoUrl: null, trackerUrl: null, adapter: 'local' }} />);
  expect(field('Tracker').textContent, 'because a local tracker has no page, only its name').toBe('Trackerlocal');
  expect(screen.queryAllByRole('link').map((link) => link.textContent), 'because a local project has no repository or tracker page to open, only the Settings link').toEqual(['Settings']);
});

test('Header_BaseBranch_ShownInMono', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect(within(field('Base branch')).getByText('main').className, 'because a branch name reads as code').toBe('mono');
});

test('InstalledPlugin_FlowPluginTitleSaysInstalled', () => {
  render(<ProjectHeader project={PROJECT} />);
  expect([field('Flow plugin').textContent, field('Flow plugin').getAttribute('title')], 'because the owner should know which copy of the plugin runs').toEqual(['Flow plugin1.17.0', 'The installed plugin, as .flow/plugin.sh finds it: /home/owner/.claude/plugins/cache/brain/flow/1.17.0']);
});

test('PluginFromTheEnvironment_FlowPluginTitleSaysFlowPlugin', () => {
  render(<ProjectHeader project={{ ...PROJECT, pluginSource: 'FLOW_PLUGIN', pluginRoot: '/work/brain/plugins/flow' }} />);
  expect(field('Flow plugin').getAttribute('title'), 'because a checkout named by FLOW_PLUGIN is not the installed plugin, and the owner must be able to tell').toBe('Set by FLOW_PLUGIN when the daemon started: /work/brain/plugins/flow');
});

test('Header_JobsRunOn_SaysTheJobsHost', () => {
  render(<ProjectHeader project={{ ...PROJECT, jobsHost: 'codex' }} />);
  expect(field('Jobs run on').textContent, 'because which CLI runs the jobs changes what the agents can do').toBe('Jobs run oncodex');
});

test('Header_AnyProject_LinksToSettings', () => {
  render(<ProjectHeader project={PROJECT} />);
  const settings = screen.getByRole('link', { name: 'Settings' });
  expect([settings.getAttribute('href'), settings.getAttribute('title')], 'because projects are added and removed there, and the tooltip says what Settings holds').toEqual(['#/settings', 'The projects the daemon watches, the terminal it opens and its port: add or remove a project there without a restart.']);
});
