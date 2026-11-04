import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test, vi } from 'vitest';
import type { AttentionRow, Disagreement, InstalledPlugin, PullRequest, Snapshot } from '../../daemon/src/snapshot.ts';
import type { Route } from '../src/route.ts';
import { Overview, tiles } from '../src/screens/Overview.tsx';
import { FIELD_ROWS_SHOWN } from '../src/screens/NeedsYou.tsx';
import { REFRESH_ALL_SOURCES, REFRESH_SETTLE_MS } from '../src/SourcesRefresh.tsx';
import { MISSING, NO_PLUGINS, PROVIDERS_DIFFER } from '../src/PluginsFooter.tsx';
import { actionRecord, boardDisagreement, readiness, boardItem, FakeDaemon, HTTP_ACCEPTED, HTTP_UNAUTHORIZED, installedPlugin, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(() => { cleanup(); vi.useRealTimers(); });

const ignoreRoute = (): void => {};

function renderOverview(snapshot: Snapshot, go: (route: Route) => void = ignoreRoute): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Overview snapshot={snapshot} go={go} /></Wrapper>);
}

function failingPull(number: number): PullRequest {
  return {
    number, title: `PR ${number}`, url: `https://github.com/owner/project/pull/${number}`, branch: `b${number}`, base: 'main', author: 'o', draft: false, state: 'checks-failing',
    checks: { passed: 0, failed: 1, pending: 0 }, checkRuns: [], head: null, autoMerge: null, reviewDecision: null, unresolvedThreads: 0, mergeable: null, mergeState: null, item: null, worktree: null,
    createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 0, idleSeconds: 0, review: null, quiz: null,
  };
}

function gateRow(id: string, ageSeconds: number): AttentionRow {
  return { kind: 'gate', gate: 'plan-approval', id, title: `Plan for ${id}`, detail: 'plan', worktree: null, sinceAt: TAKEN_AT, ageSeconds, action: null };
}

function needsField(id: string): AttentionRow {
  return { kind: 'needs-field', gate: null, id, title: `Item ${id}`, detail: 'needs priority', worktree: null, sinceAt: null, ageSeconds: null, action: null };
}

test('ClaimedPoolCell_ShowsTheItemTitle', () => {
  const claimed = { ...poolWorktree('wt-2'), state: 'claimed' as const, item: 'gh#268', itemTitle: 'Preset retune: re-arm the ladder' };
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), worktrees: [claimed] });
  expect(screen.queryByText('Preset retune: re-arm the ladder'), 'because an id alone does not say what the worktree works on').not.toBeNull();
});

test('ReadinessLine_SaysWhyNothingRuns', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), readiness: readiness({ waitingOnField: 9, nextInLineMissingField: 4, gated: 5, blocked: 12 }) });
  expect(screen.getByLabelText('Readiness').textContent, 'because the tiles alone do not say why the pool is idle').toMatch(/4 items that are next in line lack a field/);
});

test('ItemWaitingOnAField_ListedWithTheFieldNamed', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: [needsField('gh#197')] });
  const row = screen.getByText('gh#197').closest('li');
  expect(row?.textContent, 'because the owner must see which field to fill on which item').toMatch(/needs priority/);
});

test('ItemWaitingOnAField_LinksToTheTracker', () => {
  const snapshot = { ...snapshotAt(TAKEN_AT, 0), attention: [needsField('gh#197')], items: [boardItem('gh#197', 'Rod dynamics')] };
  renderOverview(snapshot);
  expect(screen.getByRole('link', { name: 'gh#197' }).getAttribute('href'), 'because the field is filled in on the tracker').toBe('https://github.com/owner/project/issues/197');
});

test('ManyItemsWaitingOnAField_FoldAfterAFew', () => {
  const rows = ['gh#1', 'gh#2', 'gh#3', 'gh#4', 'gh#5', 'gh#6', 'gh#7'].map(needsField);
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: rows });
  expect(screen.getAllByText('needs priority').length, 'because a backlog without priorities must not bury the gates').toBe(FIELD_ROWS_SHOWN);
});

test('ShowAllPressed_ListsEveryItemWaitingOnAField', () => {
  const rows = ['gh#1', 'gh#2', 'gh#3', 'gh#4', 'gh#5', 'gh#6', 'gh#7'].map(needsField);
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: rows });
  fireEvent.click(screen.getByRole('button', { name: /show all 7/i }));
  expect(screen.getAllByText('needs priority').length, 'because the fold hides rows, it does not drop them').toBe(rows.length);
});

test('Disagreement_ShowsWhatEachStoreSays', () => {
  const disagreement = boardDisagreement('gh#310');
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [disagreement] });
  expect(screen.queryByText(disagreement.explain), 'because a disagreement must say which store is usually right').not.toBeNull();
});

test('DisagreementWithAnAction_OffersItsButton', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [boardDisagreement('gh#310')] });
  expect(screen.queryByRole('button', { name: 'Re-read the board' }), 'because the fix is one press away when the daemon knows it').not.toBeNull();
});

test('DisagreementWithoutAnAction_OffersNoButton', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [{ ...boardDisagreement('gh#310'), action: null }] });
  const module = screen.getByRole('heading', { name: 'Disagreements' }).closest('section');
  expect(within(module as HTMLElement).queryByRole('button'), 'because a disagreement only a person can settle has nothing to press').toBeNull();
});

const STEP_MISMATCH: Disagreement = {
  item: 'gh#9', worktree: 'wt-3', sources: ['claim', 'issue state'], message: 'gh#9: the claim says step review, the issue says implement.',
  explain: "The claim in wt-3 says gh#9 is at step review, while the issue says implement; the claim is usually right, because it is the agent's own record and is written first, and the button writes step review to the issue as the flow does at a step change.",
  action: { kind: 'item.step-sync', args: { item: 'gh#9' }, label: "Set the issue's step to the claim's" },
};

test('StepMismatch_ButtonSetsTheIssuesStep', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', '/api/projects/project/actions', (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('s1', 'done', {}), kind: 'item.step-sync', args: { item: 'gh#9' }, outcome: 'finished' } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Overview snapshot={{ ...snapshotAt(TAKEN_AT, 0), disagreements: [STEP_MISMATCH] }} go={ignoreRoute} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: "Set the issue's step to the claim's" })); });
  expect(posted, "because the button writes the claim's step to that item's issue").toEqual([{ kind: 'item.step-sync', args: { item: 'gh#9' } }]);
});

test('Activity_ShowAllLeadsToTheActivityScreen', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.getByRole('link', { name: 'Show all' }).getAttribute('href'), 'because the overview shows only the latest events').toBe('#/project/activity');
});

test('StoppedHostRow_CarriesItsClearButton', () => {
  const stopped: AttentionRow = { kind: 'host-stopped', gate: null, id: 'codex', title: 'codex is stopped', detail: 'usage limit', worktree: null, sinceAt: TAKEN_AT, ageSeconds: 60, action: { kind: 'host.clear', args: { host: 'codex' }, label: 'Clear codex' } };
  renderOverview({ ...snapshotAt(TAKEN_AT, 1), attention: [stopped] });
  expect(screen.queryByRole('button', { name: 'Clear codex' }), 'because the row is settled from where it is seen').not.toBeNull();
});

test('Tiles_NeedsYou_NamesTheOldestRowAndItsAge', () => {
  const needsYou = tiles({ ...snapshotAt(TAKEN_AT, 2), attention: [gateRow('gh#1', 600), gateRow('gh#2', 7200)] })[0]!;
  expect(needsYou.sub, 'because the oldest wait is the one to settle first').toMatch(/^oldest 2h.* · gh#2$/);
});

test('Tiles_ChecksRed_NamesTheFailingPullsAndLeadsToPulls', () => {
  const red = tiles({ ...snapshotAt(TAKEN_AT, 0), pulls: [failingPull(81), failingPull(82)] }).find((tile) => tile.label === 'Checks red')!;
  expect([red.sub, red.screen], 'because the owner fixes a red PR from the pulls screen').toEqual(['PR #81, PR #82', 'pulls']);
});

test('GateRow_DecideOpensThatGate', () => {
  const routes: Route[] = [];
  renderOverview({ ...snapshotAt(TAKEN_AT, 1), attention: [gateRow('gh#322', 600)] }, (route) => routes.push(route));
  fireEvent.click(screen.getByRole('button', { name: 'Decide' }));
  expect(routes, 'because a gate is settled on its own page').toEqual([{ projectId: 'project', screen: 'gates', detail: 'gh#322' }]);
});

test('NothingRuns_RunningNowSaysSo', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.queryByText('No run is going.'), 'because an empty panel would look like a broken one').not.toBeNull();
});

const REFRESH_PATH = '/api/projects/project/refresh';

function renderWith(daemon: FakeDaemon, snapshot: Snapshot): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Overview snapshot={snapshot} go={ignoreRoute} /></Wrapper>);
}

function refreshButton(): HTMLButtonElement {
  return screen.getByRole('button', { name: REFRESH_ALL_SOURCES }) as HTMLButtonElement;
}

test('RefreshPressed_PostsToTheRefreshRouteAndStaysDisabledUntilSettled', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answerAfterEvents('POST', REFRESH_PATH, 1, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { refreshing: ['files'] } }; });
  renderWith(daemon, snapshotAt(TAKEN_AT, 0));
  fireEvent.click(refreshButton());
  expect([refreshButton().disabled, refreshButton().classList.contains('spinning')], 'because a second press while the daemon reads would only queue the same work, and the turning icon says it is on its way').toEqual([true, true]);
  daemon.openStream();
  await act(async () => { daemon.latestStream().send('projects', []); });
  expect([posted, refreshButton().disabled], 'because no source named means every source, and the icon keeps turning a moment after the daemon took it').toEqual([[null], true]);
  await act(async () => { vi.advanceTimersByTime(REFRESH_SETTLE_MS); });
  expect(refreshButton().disabled, 'because once settled the owner can ask again').toBe(false);
});

test('RefreshRefused_ShowsTheErrorAndCanBePressedAgain', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('POST', REFRESH_PATH, () => ({ status: HTTP_UNAUTHORIZED, body: { error: 'token needed' } }));
  renderWith(daemon, snapshotAt(TAKEN_AT, 0));
  await act(async () => { fireEvent.click(refreshButton()); });
  expect([screen.getByRole('status').textContent, refreshButton().disabled], 'because a refused refresh must say why beside the button, and a retry stays one press away').toEqual(['Refresh failed: token needed', false]);
});

function withPlugins(...plugins: InstalledPlugin[]): Snapshot {
  const snapshot = snapshotAt(TAKEN_AT, 0);
  return { ...snapshot, project: { ...snapshot.project, plugins } };
}

/** The footer's table as the owner reads it: one row per plugin, the name then each provider's cell. */
function pluginRows(): string[][] {
  const table = within(screen.getByLabelText('Installed plugins')).getByRole('table');
  return within(table).getAllByRole('row').slice(1).map((row) => Array.from(row.children, (cell) => cell.textContent ?? ''));
}

test('PluginsFooter_ListsFlowFirstThenTheOthersWithEachProvidersVersion', () => {
  renderOverview(withPlugins(installedPlugin('standards', '1.3.0', '1.3.0'), installedPlugin('craft', '1.0.0', '1.0.0'), installedPlugin('flow', '1.17.0', '1.17.0')));
  expect(pluginRows(), 'because the owner wants every plugin, flow among them, with what Claude Code and Codex each have').toEqual([['flow', '1.17.0', '1.17.0'], ['craft', '1.0.0', '1.0.0'], ['standards', '1.3.0', '1.3.0']]);
});

test('PluginsFooter_NamesTheProvidersAndTheMarketplace', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  const table = within(screen.getByLabelText('Installed plugins')).getByRole('table', { name: 'Plugins from brain' });
  expect(within(table).getAllByRole('columnheader').map((header) => header.textContent), 'because each column is one provider, said in full').toEqual(['Plugin', 'Claude Code', 'Codex']);
});

test('PluginOnOneProviderOnly_OtherCellShowsADash', () => {
  renderOverview(withPlugins(installedPlugin('meta', '1.1.2', null), installedPlugin('craft', null, '1.0.0')));
  expect(pluginRows(), 'because a plugin a provider lacks is not there for jobs on it, and an empty cell would read as not loaded').toEqual([['craft', MISSING, '1.0.0'], ['meta', '1.1.2', MISSING]]);
});

test('PluginOnDifferentVersions_BothCellsMarkedAsDiffering', () => {
  renderOverview(withPlugins(installedPlugin('flow', '1.17.0', '1.16.0'), installedPlugin('standards', '1.3.0', '1.3.0')));
  const marked = Array.from(screen.getByLabelText('Installed plugins').querySelectorAll('.plugin-differs'), (cell) => [cell.textContent, cell.getAttribute('title')]);
  expect(marked, 'because a job on Codex runs the Codex copy, so a mismatch must stand out, and only the plugin that differs').toEqual([['1.17.0', PROVIDERS_DIFFER], ['1.16.0', PROVIDERS_DIFFER]]);
});

test('InstalledFlow_FlowScriptsLineNamesTheVersionAndTheInstalledPlugin', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.getByText(/^Flow scripts/).textContent, 'because the table says what is installed, and the owner must also know which copy the scripts run').toMatch(/1\.17\.0.*installed plugin.*\/home\/owner\/\.claude\/plugins\/cache\/brain\/flow\/1\.17\.0/);
});

test('FlowFromTheEnvironment_FlowScriptsLineSaysFlowPlugin', () => {
  const snapshot = snapshotAt(TAKEN_AT, 0);
  renderOverview({ ...snapshot, project: { ...snapshot.project, pluginVersion: '1.28.0', pluginSource: 'FLOW_PLUGIN', pluginRoot: '/work/brain/plugins/flow' } });
  expect(screen.getByText(/^Flow scripts/).textContent, 'because a checkout named by FLOW_PLUGIN is not the installed plugin, and the owner must be able to tell').toMatch(/1\.28\.0.*FLOW_PLUGIN.*\/work\/brain\/plugins\/flow/);
});

test('NoPluginsFound_FooterSaysWhereItLooked', () => {
  renderOverview(withPlugins());
  const footer = screen.getByLabelText('Installed plugins');
  expect([within(footer).queryByRole('table'), within(footer).queryByText(NO_PLUGINS)], 'because an empty table would read as not loaded yet').toEqual([null, expect.anything()]);
});

test('RunningNow_Header_LinksToAgentsAndJobs', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  const running = screen.getByRole('heading', { name: 'Running now' }).closest('section, article, details, div.module') as HTMLElement;
  expect(within(running).getByRole('link', { name: 'Agents' }).getAttribute('href'), 'because the runs live on the Agents page').toMatch(/\/agents$/);
  expect(within(running).getByRole('link', { name: 'Jobs' }).getAttribute('href'), 'because the scheduled jobs listed here live on the Jobs page').toMatch(/\/jobs$/);
});

/** The Overview of a project whose last retro was followed by three lessons. */
function renderWithLessonsSinceRetro(): void {
  const base = snapshotAt(TAKEN_AT, 0);
  const retro = { date: '2026-10-19', at: '2026-10-19T07:00:31Z', lessonsRead: 1, lessonsReadSoFar: 3, findings: '', applied: '', report: null };
  renderOverview({ ...base, retros: [retro], counts: { ...base.counts, lessonsSinceRetro: 3 } });
}

test('Overview_LessonsSinceTheLastRetro_Counted', () => {
  renderWithLessonsSinceRetro();
  expect(screen.getByLabelText('Lessons').textContent, 'because the owner sees what the next retro will read without opening the page').toMatch(/3 lessons since the last retro/);
});

test('Overview_LessonsLine_LinksToTheRetroPage', () => {
  renderWithLessonsSinceRetro();
  expect(within(screen.getByLabelText('Lessons')).getByRole('link', { name: 'Retro' }).getAttribute('href'), 'because the count leads to the lessons themselves').toBe('#/project/retro');
});
