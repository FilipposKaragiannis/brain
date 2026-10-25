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
  sections: schemaSections(), warnings: [], hostDefaults: { codex: { model: 'gpt-6-sol', effort: 'high', profile: null } },
};

async function renderFlowSettings(onPut: (body: unknown) => { status: number; body: unknown }, document: FlowConfigDocument = DOCUMENT) {
  const daemon = new FakeDaemon();
  const puts: unknown[] = [];
  const posts: unknown[] = [];
  daemon.answer('GET', CONFIG, () => ({ status: HTTP_OK, body: document }));
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
  expect(field.textContent, 'because the help says what changing the key does').toMatch(/Which CLI runs the scheduled jobs\. The workers inside a run keep their own models\./);
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

function jobs(): HTMLElement {
  return group('Jobs');
}
function optionsOf(label: string): string[] {
  return [...(within(jobs()).getByLabelText(label) as HTMLSelectElement).options].map((option) => option.textContent ?? '');
}
const withJobs = (extra: Record<string, unknown>): FlowConfigDocument => ({ ...DOCUMENT, values: { ...DOCUMENT.values, jobs: { host: 'claude', schedule: { next: 'every 30m --workers 2' }, ...extra } } });

test('JobsGroup_HostClaude_OnlyClaudesModelAndEffortShow', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ codex: { model: 'gpt-6-luna' } }));
  expect(within(jobs()).queryByLabelText('jobs.claude.model'), 'because the jobs run on claude, so its model is the one that counts').not.toBeNull();
  expect(within(jobs()).queryByLabelText('jobs.claude.effort'), 'because the effort goes with the model').not.toBeNull();
  expect([within(jobs()).queryByLabelText('jobs.codex.model'), within(jobs()).queryByLabelText('jobs.codex.effort')], 'because the other host\'s pair is hidden while the jobs do not run on it').toEqual([null, null]);
  expect(optionsOf('jobs.claude.model'), 'because the dropdown lists the enum, with the empty value as the host\'s default').toEqual(['host default', 'opus', 'sonnet', 'haiku', 'fable', 'other…']);
  expect(within(jobs()).getByLabelText('jobs.claude.model').closest('.flow-field')!.textContent, 'because claude has no file that names its default').toMatch(/empty takes the Claude CLI's default/);
});

test('JobsGroup_HostSwitchedToCodex_CodexPairShowsWithThisMachinesDefault', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ codex: { model: 'gpt-6-luna' } }));
  fireEvent.change(within(jobs()).getByLabelText('jobs.host'), { target: { value: 'codex' } });
  expect(within(jobs()).queryByLabelText('jobs.claude.model'), 'because the pair follows the host as picked, before any save').toBeNull();
  expect((within(jobs()).getByLabelText('jobs.codex.model') as HTMLSelectElement).value, 'because the hidden pair kept its saved value').toBe('gpt-6-luna');
  expect(optionsOf('jobs.codex.effort'), 'because codex takes no max effort').toEqual(['host default', 'low', 'medium', 'high', 'xhigh']);
  expect(within(jobs()).getByLabelText('jobs.codex.model').closest('.flow-field')!.textContent, 'because the daemon read the default from ~/.codex/config.toml').toMatch(/On this machine that is gpt-6-sol/);
  expect(within(jobs()).getByLabelText('jobs.codex.effort').closest('.flow-field')!.textContent, 'because the effort default comes from model_reasoning_effort').toMatch(/On this machine that is high/);
});

test('JobsGroup_HiddenPairEdited_NotSent', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.codex.effort', 'jobs.host'] }) }));
  fireEvent.change(within(jobs()).getByLabelText('jobs.claude.model'), { target: { value: 'opus' } });
  fireEvent.change(within(jobs()).getByLabelText('jobs.host'), { target: { value: 'codex' } });
  fireEvent.change(within(jobs()).getByLabelText('jobs.codex.effort'), { target: { value: 'xhigh' } });
  await act(async () => { fireEvent.click(within(jobs()).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because a change to the pair the owner can no longer see must not be saved behind their back, and the shown pair goes whole').toEqual([{ changes: [{ path: 'jobs.host', value: 'codex' }, { path: 'jobs.codex.model', value: '' }, { path: 'jobs.codex.effort', value: 'xhigh' }], hash: 'h1' }]);
});

test('JobsGroup_NoCodexConfig_HelpSaysCodexPicks', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), { ...withJobs({ host: 'codex' }), hostDefaults: { codex: null } });
  expect(within(jobs()).getByLabelText('jobs.codex.model').closest('.flow-field')!.textContent, 'because without the file the console cannot name the default').toMatch(/no ~\/\.codex\/config\.toml/);
});

test('DeprecatedJobsModel_NotSet_Hidden', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ model: '', effort: '' }));
  expect([within(jobs()).queryByLabelText('jobs.model'), within(jobs()).queryByLabelText('jobs.effort')], 'because a key the flow no longer reads is only worth showing when the file still sets it').toEqual([null, null]);
});

test('DeprecatedJobsModel_Set_ReadOnlyWithTheNoteAndClearSendsNull', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.model'] }) }), withJobs({ model: 'opus' }));
  const input = within(jobs()).getByLabelText('jobs.model') as HTMLInputElement;
  expect([input.value, input.readOnly], 'because the value shows, but is not edited here any more').toEqual(['opus', true]);
  expect(input.closest('.flow-field')!.textContent, 'because the owner learns what replaced it').toMatch(/Deprecated: flow 1\.20\.0 reads jobs\.<host>\.model and jobs\.<host>\.effort, and this key only while jobs\.<host> is absent\. Set those and clear these\./);
  expect(within(jobs()).queryByLabelText('jobs.effort'), 'because only the deprecated key the file sets shows').toBeNull();
  await act(async () => { fireEvent.click(within(jobs()).getByRole('button', { name: 'Clear jobs.model' })); });
  expect(puts, 'because Clear takes the key out of the file').toEqual([{ changes: [{ path: 'jobs.model', value: null }], hash: 'h1' }]);
  expect(within(jobs()).getByRole('status').textContent, 'because the owner sees the key went').toMatch(/Saved jobs\.model\./);
});

test('JobsGroup_NoClaudeMapAndOldModelSet_ShowsWhatThePluginRunsAndHostDefaultWritesTheMap', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.claude.model', 'jobs.claude.effort'] }) }), withJobs({ model: 'opus' }));
  const model = within(jobs()).getByLabelText('jobs.claude.model') as HTMLSelectElement;
  expect(model.value, 'because with no jobs.claude map the plugin falls back to jobs.model, so the jobs run opus').toBe('opus');
  expect(model.closest('.flow-field')!.textContent, 'because the owner must see where that value comes from').toMatch(/now opus, from the deprecated jobs\.model/);
  expect(within(jobs()).getByLabelText('jobs.claude.effort').closest('.flow-field')!.textContent, 'because jobs.effort is empty, so nothing is taken from it').not.toMatch(/from the deprecated/);
  fireEvent.change(model, { target: { value: '' } });
  await act(async () => { fireEvent.click(within(jobs()).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because host default is an empty line in a jobs.claude map, the one thing that ends the fallback').toEqual([{ changes: [{ path: 'jobs.claude.model', value: '' }, { path: 'jobs.claude.effort', value: '' }], hash: 'h1' }]);
});

test('JobsGroup_NoCodexMapAndOldModelSet_ShowsTheMappedName', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ host: 'codex', model: 'opus', effort: 'max' }));
  expect((within(jobs()).getByLabelText('jobs.codex.model') as HTMLSelectElement).value, 'because the plugin maps the roster name opus to gpt-6-sol for codex').toBe('gpt-6-sol');
  expect(within(jobs()).getByLabelText('jobs.codex.model').closest('.flow-field')!.textContent, 'because the value comes from the old key').toMatch(/now gpt-6-sol, from the deprecated jobs\.model/);
  expect(within(jobs()).getByLabelText('jobs.codex.effort').closest('.flow-field')!.textContent, 'because the old effort counts too, even one codex refuses').toMatch(/now max, from the deprecated jobs\.effort/);
});

test('JobsGroup_ClaudeMapPresent_OldModelIgnored', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ model: 'opus', claude: { effort: 'low' } }));
  const model = within(jobs()).getByLabelText('jobs.claude.model') as HTMLSelectElement;
  expect([model.value, /from the deprecated/.test(model.closest('.flow-field')!.textContent ?? '')], 'because once jobs.claude is there the plugin reads only it, and its missing model is the host default').toEqual(['', false]);
});

test('JobsGroup_ModelNotInTheList_ShownInOtherAndAnyNameSaves', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.claude.model'] }) }), withJobs({ claude: { model: 'claude-opus-x', effort: 'high' } }));
  expect((within(jobs()).getByLabelText('jobs.claude.model') as HTMLSelectElement).selectedOptions[0]!.textContent, 'because the plugin passes any model name on, so one off the list is still a value').toBe('other…');
  const text = within(jobs()).getByLabelText('jobs.claude.model, other') as HTMLInputElement;
  expect(text.value, 'because the text field holds the name the file has').toBe('claude-opus-x');
  fireEvent.change(text, { target: { value: 'claude-opus-y' } });
  await act(async () => { fireEvent.click(within(jobs()).getByRole('button', { name: 'Save' })); });
  expect(puts, 'because a free name saves as typed, with the effort of the pair').toEqual([{ changes: [{ path: 'jobs.claude.model', value: 'claude-opus-y' }, { path: 'jobs.claude.effort', value: 'high' }], hash: 'h1' }]);
});

test('JobsGroup_OtherPicked_RevealsTheTextFieldAndAListedPickHidesIt', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const model = within(jobs()).getByLabelText('jobs.claude.model') as HTMLSelectElement;
  expect(within(jobs()).queryByLabelText('jobs.claude.model, other'), 'because a listed value needs no text field').toBeNull();
  fireEvent.change(model, { target: { value: [...model.options].find((option) => option.textContent === 'other…')!.value } });
  expect(within(jobs()).queryByLabelText('jobs.claude.model, other'), 'because other… is for a name off the list').not.toBeNull();
  fireEvent.change(model, { target: { value: 'sonnet' } });
  expect([within(jobs()).queryByLabelText('jobs.claude.model, other'), model.value], 'because a listed pick closes it again').toEqual([null, 'sonnet']);
});

test('DeprecatedJobsModel_Cleared_TheGroupsOtherEditsStay', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.model'] }) }), withJobs({ model: 'opus' }));
  fireEvent.change(within(jobs()).getByLabelText('jobs.marketplace'), { target: { value: '/work/other' } });
  await act(async () => { fireEvent.click(within(jobs()).getByRole('button', { name: 'Clear jobs.model' })); });
  expect((within(jobs()).getByLabelText('jobs.marketplace') as HTMLInputElement).value, 'because a Clear saves one key and must not throw away what else the owner typed').toBe('/work/other');
  expect((within(jobs()).getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled, 'because that edit is still to be saved').toBe(false);
});
