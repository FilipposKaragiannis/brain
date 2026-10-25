import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { FlowConfigDocument, FlowConfigSaved } from '../../daemon/src/plugins/flow/schema.ts';
import { schemaSections } from '../../daemon/src/plugins/flow/schema.ts';
import { FlowSettings, TRACKED_NOTE } from '../src/screens/FlowSettings.tsx';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, HTTP_CONFLICT, HTTP_OK } from './fakeDaemon.tsx';

afterEach(cleanup);

const CONFIG = '/api/projects/project/plugins/flow/config';
const TEXT = 'base: main\njobs:\n  host: claude\n  schedule:\n    next: every 30m --workers 2\nreviews:\n  reviewers: [codex]\n';
const DOCUMENT: FlowConfigDocument = {
  path: '/p/.flow/config.yaml', text: TEXT, hash: 'h1',
  values: { base: 'main', jobs: { host: 'claude', schedule: { next: 'every 30m --workers 2' } }, reviews: { reviewers: ['codex'] } },
  sections: schemaSections(), warnings: [],
};

async function renderFlowSettings(onPut: (body: unknown) => { status: number; body: unknown }) {
  const daemon = new FakeDaemon();
  const puts: unknown[] = [];
  const posts: unknown[] = [];
  daemon.answer('GET', CONFIG, () => ({ status: HTTP_OK, body: DOCUMENT }));
  daemon.answer('PUT', CONFIG, (body) => { puts.push(body); return onPut(body); });
  daemon.answer('POST', '/api/projects/project/actions', (body) => { posts.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('a1', 'running', {}), kind: 'jobs.install' } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><FlowSettings projectId="project" name="foosbrawl" /></Wrapper>);
  await act(async () => {});
  return { puts, posts };
}

function group(name: string): HTMLElement {
  return screen.getByRole('form', { name });
}

const saved = (saved: Partial<FlowConfigSaved>): FlowConfigSaved => ({ ...DOCUMENT, hash: 'h2', saved: [], followUps: [], notes: [], ...saved });

test('FlowSettings_Read_TitledForTheProjectWithTheTrackedNote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(screen.getByRole('heading', { name: 'flow settings for foosbrawl' }), 'because each project gets its own section').not.toBeNull();
  expect(screen.queryByText(TRACKED_NOTE), 'because the owner must commit the change in the project, the console does not').not.toBeNull();
});

test('FlowSettings_Read_OneFormPerSchemaGroup', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(screen.getAllByRole('form').map((form) => form.getAttribute('aria-label')), 'because the keys are grouped the way the flow uses them').toEqual(['Tracker', 'Readiness', 'Worktree pool', 'Gates and verification', 'Reviews', 'Notifications', 'Jobs', 'Intake']);
});

test('FlowSettings_Field_LabelledByItsKeyWithTheHelpUnderIt', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const field = within(group('Jobs')).getByLabelText('jobs.host').closest('.flow-field')!;
  expect(field.textContent, 'because the help says what changing the key does').toMatch(/Which CLI the scheduled jobs run unattended/);
  expect((within(group('Jobs')).getByLabelText('jobs.host') as HTMLSelectElement).value, 'because the control starts at the file\'s value').toBe('claude');
});

test('FlowSettings_NothingChanged_SaveDisabled', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect((within(group('Jobs')).getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled, 'because a save with no change would only rewrite the same file').toBe(true);
});

test('FlowSettings_ScheduleChanged_SavesItAndOffersTheReload', async () => {
  const followUps = [{ note: 'The schedule launchd runs is written at install: run jobs.sh install to reload it.', action: { kind: 'jobs.install' as const, label: 'Reload the schedule', args: {} }, paths: ['jobs.schedule.next'] }];
  const { puts, posts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.schedule.next'], followUps }) }));
  fireEvent.change(within(group('Jobs')).getByLabelText('jobs.schedule.next'), { target: { value: 'every 20m --workers 2' } });
  await act(async () => { fireEvent.click(within(group('Jobs')).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because only the changed key goes, with the hash the file was read with').toEqual([{ changes: [{ path: 'jobs.schedule.next', value: 'every 20m --workers 2' }], hash: 'h1' }]);
  expect(within(group('Jobs')).getByRole('status').textContent, 'because the owner sees what was written and what it needs').toMatch(/Saved jobs\.schedule\.next\..*jobs\.sh install/);
  await act(async () => { fireEvent.click(within(group('Jobs')).getByRole('button', { name: 'Reload the schedule' })); });
  expect(posts, 'because launchd runs the old schedule until jobs.sh install writes the new one').toEqual([{ kind: 'jobs.install', args: {} }]);
});

test('FlowSettings_ListChanged_SentAsAList', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['reviews.reviewers'] }) }));
  fireEvent.change(within(group('Reviews')).getByLabelText('reviews.reviewers'), { target: { value: 'codex\ncopilot\n' } });
  await act(async () => { fireEvent.click(within(group('Reviews')).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because a list is one item per line in the form and a list in the file').toEqual([{ changes: [{ path: 'reviews.reviewers', value: ['codex', 'copilot'] }], hash: 'h1' }]);
});

test('FlowSettings_DirtyFile_RefusedAndSaveAnywayForces', async () => {
  let calls = 0;
  const { puts } = await renderFlowSettings(() => {
    calls += 1;
    return calls === 1
      ? { status: HTTP_CONFLICT, body: { reason: 'dirty', error: '.flow/config.yaml has uncommitted changes in git' } }
      : { status: HTTP_OK, body: saved({ saved: ['base'] }) };
  });
  fireEvent.change(within(group('Worktree pool')).getByLabelText('base'), { target: { value: 'dev' } });
  await act(async () => { fireEvent.click(within(group('Worktree pool')).getByRole('button', { name: 'Save' })); });
  expect(within(group('Worktree pool')).getByRole('alert').textContent, 'because the owner hears why nothing was written').toMatch(/uncommitted changes/);
  await act(async () => { fireEvent.click(within(group('Worktree pool')).getByRole('button', { name: 'Save anyway' })); });
  expect(puts.at(-1), 'because Save anyway is the same change with force').toEqual({ changes: [{ path: 'base', value: 'dev' }], hash: 'h1', force: true });
});

test('FlowSettings_RawYaml_SavesTheWholeText', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['base'] }) }));
  const raw = screen.getByLabelText('Raw YAML for foosbrawl');
  fireEvent.change(raw, { target: { value: TEXT.replace('base: main', 'base: dev') } });
  await act(async () => { fireEvent.click(within(raw.closest('form')!).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because Raw YAML writes the file as typed, checked like the form').toEqual([{ text: TEXT.replace('base: main', 'base: dev'), hash: 'h1' }]);
});

test('FlowSettings_ScheduleRemoved_OffersToUnloadThatJob', async () => {
  const followUps = [{ note: "jobs.sh install loads only jobs with a schedule, so retro's launchd agent keeps running until jobs.sh uninstall retro unloads it.", action: { kind: 'job.uninstall' as const, label: 'Unload retro', args: { job: 'retro' } }, paths: ['jobs.schedule.retro'] }];
  const { posts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.schedule.retro'], followUps }) }));
  fireEvent.change(within(group('Jobs')).getByLabelText('jobs.schedule.next'), { target: { value: '' } });
  await act(async () => { fireEvent.click(within(group('Jobs')).getByRole('button', { name: 'Save' })); });
  expect(within(group('Jobs')).getByRole('status').textContent, 'because the owner must hear that install alone leaves the job running').toMatch(/keeps running until jobs\.sh uninstall retro/);
  await act(async () => { fireEvent.click(within(group('Jobs')).getByRole('button', { name: 'Unload retro' })); });
  expect(posts, 'because the button unloads that one job').toEqual([{ kind: 'job.uninstall', args: { job: 'retro' } }]);
});

test('FlowSettings_UntrackedFile_SavedWithTheNote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['base'], notes: ['.flow/config.yaml is not tracked by git: add and commit it to keep the change'] }) }));
  fireEvent.change(within(group('Worktree pool')).getByLabelText('base'), { target: { value: 'dev' } });
  await act(async () => { fireEvent.click(within(group('Worktree pool')).getByRole('button', { name: 'Save' })); });
  expect(within(group('Worktree pool')).getByRole('status').textContent, 'because an untracked file saves without Save anyway, but the owner should know git does not keep it').toMatch(/not tracked by git/);
});
