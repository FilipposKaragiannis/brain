import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { FlowConfigDocument, FlowConfigSaved } from '../../daemon/src/plugins/flow/schema.ts';
import { fieldAt, schemaSections } from '../../daemon/src/plugins/flow/schema.ts';
import type { FlowShown } from '../src/screens/FlowSettings.tsx';
import { FlowSettings, NO_GITHUB, NO_JIRA, TRACKED_NOTE } from '../src/screens/FlowSettings.tsx';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, HTTP_CONFLICT, HTTP_OK } from './fakeDaemon.tsx';

afterEach(cleanup);

const CONFIG = '/api/projects/project/plugins/flow/config';
const TEXT = 'base: main\njobs:\n  host: claude\n  schedule:\n    next: every 30m --workers 2\nreviews:\n  reviewers: [codex]\n';
const DOCUMENT: FlowConfigDocument = {
  path: '/p/.flow/config.yaml', text: TEXT, hash: 'h1',
  values: { base: 'main', jobs: { host: 'claude', schedule: { next: 'every 30m --workers 2' } }, reviews: { reviewers: ['codex'] } },
  sections: schemaSections(), warnings: [], hostDefaults: { codex: { model: 'gpt-6-sol', effort: 'high', profile: null } },
};

async function renderFlowSettings(onPut: (body: unknown) => { status: number; body: unknown }, document: FlowConfigDocument = DOCUMENT, show: FlowShown = 'all') {
  const daemon = new FakeDaemon();
  const puts: unknown[] = [];
  const posts: unknown[] = [];
  daemon.answer('GET', CONFIG, () => ({ status: HTTP_OK, body: document }));
  daemon.answer('PUT', CONFIG, (body) => { puts.push(body); return onPut(body); });
  daemon.answer('POST', '/api/projects/project/actions', (body) => { posts.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('a1', 'running', {}), kind: 'jobs.install' } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><FlowSettings projectId="project" name="foosbrawl" show={show} /></Wrapper>);
  await act(async () => {});
  return { puts, posts };
}

function group(name: string): HTMLElement {
  return screen.getByRole('group', { name });
}

/** The builder of one schedule, the group its field's name labels. */
function schedule(path: string): HTMLElement {
  return within(group('Schedules')).getByRole('group', { name: label(path) });
}

/** A field's plain name, which labels its control. */
function label(path: string): string {
  return fieldAt(path)!.label;
}

/** The one save bar under every group. */
function bar(): HTMLElement {
  return screen.getByRole('region', { name: 'Save for foosbrawl' });
}

/** What the save bar says: the pending count and the result of the last save. */
function said(): string {
  return within(bar()).getAllByRole('status').map((status) => status.textContent).join(' ');
}

function saveButton(): HTMLButtonElement {
  return within(bar()).getByRole('button', { name: 'Save changes' }) as HTMLButtonElement;
}

const saved = (saved: Partial<FlowConfigSaved>): FlowConfigSaved => ({ ...DOCUMENT, hash: 'h2', saved: [], followUps: [], notes: [], ...saved });

test('FlowSettings_Read_TitledForTheProjectWithTheTrackedNote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(screen.getByRole('heading', { name: 'flow settings for foosbrawl' }), 'because each project gets its own section').not.toBeNull();
  expect(screen.queryByText(TRACKED_NOTE), 'because the owner must commit the change in the project, the console does not').not.toBeNull();
});

test('FlowSettings_Read_OneFormWithAFieldsetPerSchemaGroup', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(within(screen.getByRole('form', { name: 'flow settings form for foosbrawl' })).getAllByRole('group').filter((group) => group.tagName === 'FIELDSET').map((fieldset) => fieldset.getAttribute('aria-label')), 'because the keys are grouped the way the flow uses them, and one save sends every group').toEqual(['Tracker', 'Readiness', 'Worktree pool', 'Gates and verification', 'Reviews', 'Notifications', 'Schedules', 'Next job', 'Health job', 'Comments job', 'Retro job', 'Intake job', 'Agents']);
});

test('FlowSettings_Field_LabelledInWordsWithTheKeyAndTheHelpUnderIt', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const field = within(group('Schedules')).getByLabelText(label('jobs.host')).closest('.flow-field')!;
  expect(field.textContent, 'because the key names the line in the file and the help says what changing it does').toMatch(/jobs\.host.*Which CLI runs the scheduled jobs whose schedule names no host\. The workers inside a run keep their own models\./);
  expect((within(group('Schedules')).getByLabelText(label('jobs.host')) as HTMLSelectElement).value, 'because the control starts at the file\'s value').toBe('claude');
});

test('FlowSettings_NothingChanged_SaveDisabled', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(saveButton().disabled, 'because a save with no change would only rewrite the same file').toBe(true);
});

test('FlowSettings_ScheduleChanged_SavesItAndOffersTheReload', async () => {
  const followUps = [{ note: 'The schedule launchd runs is written at install: run jobs.sh install to reload it.', action: { kind: 'jobs.install' as const, label: 'Reload the schedule', args: {} }, paths: ['jobs.schedule.next'] }];
  const { puts, posts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.schedule.next'], followUps }) }));
  fireEvent.change(within(schedule('jobs.schedule.next')).getByLabelText('Every'), { target: { value: '20' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because only the changed key goes, with the hash the file was read with').toEqual([{ changes: [{ path: 'jobs.schedule.next', value: 'every 20m --workers 2' }], hash: 'h1' }]);
  expect(said(), 'because the owner sees what was written and what it needs').toMatch(new RegExp(`Saved ${label('jobs.schedule.next')}\\..*jobs\\.sh install`));
  await act(async () => { fireEvent.click(within(bar()).getByRole('button', { name: 'Reload the schedule' })); });
  expect(posts, 'because launchd runs the old schedule until jobs.sh install writes the new one').toEqual([{ kind: 'jobs.install', args: {} }]);
});

test('FlowSettings_ListChanged_SentAsAList', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['reviews.reviewers.claude'] }) }));
  fireEvent.change(within(group('Reviews')).getByLabelText(label('reviews.reviewers.claude')), { target: { value: 'codex\ncopilot\n' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because a list is one item per line in the form and a list in the file').toEqual([{ changes: [{ path: 'reviews.reviewers.claude', value: ['codex', 'copilot'] }], hash: 'h1' }]);
});

test('FlowSettings_PlainReviewersList_ShownAsTheDefaultReviewers', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const field = within(group('Reviews')).getByLabelText(label('reviews.reviewers.default')) as HTMLTextAreaElement;
  expect(field.value, 'because a plain reviews.reviewers list is the list every PR gets, the default').toBe('codex');
});

test('FlowSettings_DirtyFile_RefusedAndSaveAnywayForces', async () => {
  let calls = 0;
  const { puts } = await renderFlowSettings(() => {
    calls += 1;
    return calls === 1
      ? { status: HTTP_CONFLICT, body: { reason: 'dirty', error: '.flow/config.yaml has uncommitted changes in git' } }
      : { status: HTTP_OK, body: saved({ saved: ['base'] }) };
  });
  fireEvent.change(within(group('Worktree pool')).getByLabelText(label('base')), { target: { value: 'dev' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(within(bar()).getByRole('alert').textContent, 'because the owner hears why nothing was written').toMatch(/uncommitted changes/);
  await act(async () => { fireEvent.click(within(bar()).getByRole('button', { name: 'Save anyway' })); });
  expect(puts.at(-1), 'because Save anyway is the same change with force').toEqual({ changes: [{ path: 'base', value: 'dev' }], hash: 'h1', force: true });
});

test('FlowSettings_RawYaml_SavesTheWholeText', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['base'] }) }));
  const raw = screen.getByLabelText('Raw YAML for foosbrawl');
  fireEvent.change(raw, { target: { value: TEXT.replace('base: main', 'base: dev') } });
  await act(async () => { fireEvent.click(within(raw.closest('form')!).getByRole('button', { name: 'Save YAML' })); });
  expect(puts, 'because Raw YAML writes the file as typed, checked like the form').toEqual([{ text: TEXT.replace('base: main', 'base: dev'), hash: 'h1' }]);
});

test('FlowSettings_ScheduleRemoved_OffersToUnloadThatJob', async () => {
  const followUps = [{ note: "jobs.sh install loads only jobs with a schedule, so retro's launchd agent keeps running until jobs.sh uninstall retro unloads it.", action: { kind: 'job.uninstall' as const, label: 'Unload retro', args: { job: 'retro' } }, paths: ['jobs.schedule.retro'] }];
  const { posts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.schedule.retro'], followUps }) }));
  fireEvent.click(within(schedule('jobs.schedule.next')).getByRole('button', { name: 'Unschedule' }));
  await act(async () => { fireEvent.click(saveButton()); });
  expect(said(), 'because the owner must hear that install alone leaves the job running').toMatch(/keeps running until jobs\.sh uninstall retro/);
  await act(async () => { fireEvent.click(within(bar()).getByRole('button', { name: 'Unload retro' })); });
  expect(posts, 'because the button unloads that one job').toEqual([{ kind: 'job.uninstall', args: { job: 'retro' } }]);
});

test('FlowSettings_UntrackedFile_SavedWithTheNote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['base'], notes: ['.flow/config.yaml is not tracked by git: add and commit it to keep the change'] }) }));
  fireEvent.change(within(group('Worktree pool')).getByLabelText(label('base')), { target: { value: 'dev' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(said(), 'because an untracked file saves without Save anyway, but the owner should know git does not keep it').toMatch(/not tracked by git/);
});

test('FlowSettings_KeyTheFileLeavesOut_MarkedDefaultBesideItsName', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const mark = (field: HTMLElement): string | null => field.closest('.flow-field')!.querySelector('.flow-label .flow-default')?.textContent ?? null;
  const unset = mark(schedule('jobs.schedule.retro'));
  const set = mark(within(group('Schedules')).getByLabelText(label('jobs.host')));
  expect(unset, 'because a key the file leaves out runs on the default, and the label says so').toBe('default');
  expect(set, 'because a key the file sets is no default').toBeNull();
  expect(document.querySelector('details.flow-more'), 'because every field shows together in schema order, with no fold for the defaults').toBeNull();
});

test('FlowSettings_UnsetFieldEdited_StillMarkedDefaultUntilSaved', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const field = within(group('Worktree pool')).getByLabelText(label('pool_max')) as HTMLInputElement;
  fireEvent.change(field, { target: { value: '4' } });
  expect(field.closest('.flow-field')!.querySelector('.flow-default')?.textContent, 'because the mark follows the file, so it does not jump while the owner types').toBe('default');
});

test('FlowSettings_EditsInTwoGroups_OneSaveSendsBoth', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['base', 'reviews.reviewers.default'] }) }));
  fireEvent.change(within(group('Worktree pool')).getByLabelText(label('base')), { target: { value: 'dev' } });
  fireEvent.change(within(group('Reviews')).getByLabelText(label('reviews.reviewers.default')), { target: { value: 'codex\ncopilot' } });
  expect(said(), 'because the bar counts every edit before the save').toMatch(/2 unsaved changes in Worktree pool, Reviews\./);
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because one save writes the file once').toEqual([{ changes: [{ path: 'base', value: 'dev' }, { path: 'reviews.reviewers.default', value: ['codex', 'copilot'] }], hash: 'h1' }]);
});

test('FlowSettings_Discard_DropsEveryEdit', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  fireEvent.change(within(group('Worktree pool')).getByLabelText(label('base')), { target: { value: 'dev' } });
  fireEvent.click(within(bar()).getByRole('button', { name: 'Discard' }));
  expect([(within(group('Worktree pool')).getByLabelText(label('base')) as HTMLInputElement).value, said()], 'because Discard puts back what the file says').toEqual(['main', 'No unsaved changes.']);
});

test('FlowSettings_OneGroupShown_TheOthersHidden', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), DOCUMENT, 'Schedules');
  expect([screen.queryByRole('group', { name: 'Schedules' }), screen.queryByRole('group', { name: 'Tracker' })], 'because the page shows the group picked beside it').toEqual([expect.anything(), null]);
});

function agents(): HTMLElement {
  return group('Agents');
}
function optionsOf(label: string): string[] {
  return [...(within(agents()).getByLabelText(label) as HTMLSelectElement).options].map((option) => option.textContent ?? '');
}
const withJobs = (extra: Record<string, unknown>): FlowConfigDocument => ({ ...DOCUMENT, values: { ...DOCUMENT.values, jobs: { host: 'claude', schedule: { next: 'every 30m --workers 2' }, ...extra } } });

test('AgentsPage_HostClaude_BothHostsPairsShow', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ codex: { model: 'gpt-6-luna' } }));
  const shown = ['jobs.claude.model', 'jobs.claude.effort', 'jobs.codex.model', 'jobs.codex.effort'].map((path) => within(agents()).queryByLabelText(label(path)) !== null);
  expect(shown, 'because workers and schedules run on either host whatever jobs.host names').toEqual([true, true, true, true]);
  expect((within(agents()).getByLabelText(label('jobs.codex.model')) as HTMLSelectElement).value, 'because the control starts at the file\'s value').toBe('gpt-6-luna');
  expect(optionsOf(label('jobs.claude.model')), 'because the dropdown lists the enum, with the empty value as the host\'s default').toEqual(['host default', 'opus', 'sonnet', 'haiku', 'fable', 'other…']);
  expect(within(agents()).getByLabelText(label('jobs.claude.model')).closest('.flow-field')!.textContent, 'because claude has no file that names its default').toMatch(/empty takes the Claude CLI's default/);
});

test('AgentsPage_HostModel_HelpSaysEveryStepWithoutAnAgent', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  expect(within(agents()).getByLabelText(label('jobs.claude.model')).closest('.flow-field')!.textContent, 'because since flow 1.22.0 the pair runs the agent-less steps too, not only the jobs').toMatch(/without an agent of its own: the steps with no agent \(design, implement, review, explain\) and the comments, intake and retro jobs/);
  expect(within(agents()).getByLabelText(label('jobs.claude.effort')).closest('.flow-field')!.textContent, 'because the owner sees the efforts flow accepts before a run stops on one').toMatch(/low, medium, high, xhigh or max, the values flow accepts/);
  expect(within(agents()).getByLabelText(label('jobs.codex.effort')).closest('.flow-field')!.textContent, 'because codex takes no max').toMatch(/low, medium, high or xhigh, the values flow accepts/);
});

test('AgentsPage_CodexPair_ShowsThisMachinesDefault', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ codex: { model: 'gpt-6-luna' } }));
  expect(optionsOf(label('jobs.codex.effort')), 'because codex takes no max effort').toEqual(['host default', 'low', 'medium', 'high', 'xhigh']);
  expect(within(agents()).getByLabelText(label('jobs.codex.model')).closest('.flow-field')!.textContent, 'because the daemon read the default from ~/.codex/config.toml').toMatch(/On this machine that is gpt-6-sol/);
  expect(within(agents()).getByLabelText(label('jobs.codex.effort')).closest('.flow-field')!.textContent, 'because the effort default comes from model_reasoning_effort').toMatch(/On this machine that is high/);
});

test('AgentsPage_OneHostsEffortEdited_ThatPairGoesWholeTheOtherStays', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.codex.effort'] }) }));
  fireEvent.change(within(agents()).getByLabelText(label('jobs.codex.effort')), { target: { value: 'xhigh' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because a host\'s map is written whole, and the untouched host\'s pair is not sent').toEqual([{ changes: [{ path: 'jobs.codex.model', value: '' }, { path: 'jobs.codex.effort', value: 'xhigh' }], hash: 'h1' }]);
});

test('AgentsPage_NoCodexConfig_HelpSaysCodexPicks', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), { ...withJobs({ host: 'codex' }), hostDefaults: { codex: null } });
  expect(within(agents()).getByLabelText(label('jobs.codex.model')).closest('.flow-field')!.textContent, 'because without the file the console cannot name the default').toMatch(/no ~\/\.codex\/config\.toml/);
});

test('DeprecatedJobsModel_NotSet_Hidden', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ model: '', effort: '' }));
  expect([within(agents()).queryByLabelText(label('jobs.model')), within(agents()).queryByLabelText(label('jobs.effort'))], 'because a key the flow no longer reads is only worth showing when the file still sets it').toEqual([null, null]);
});

test('DeprecatedJobsModel_Set_ReadOnlyWithTheNoteAndClearSendsNull', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.model'] }) }), withJobs({ model: 'opus' }));
  const input = within(agents()).getByLabelText(label('jobs.model')) as HTMLInputElement;
  expect([input.value, input.readOnly], 'because the value shows, but is not edited here any more').toEqual(['opus', true]);
  expect(input.closest('.flow-field')!.textContent, 'because the owner learns what replaced it').toMatch(/Deprecated: flow 1\.20\.0 reads jobs\.<host>\.model and jobs\.<host>\.effort, and this key only while jobs\.<host> is absent\. Set those and clear these\./);
  expect(within(agents()).queryByLabelText(label('jobs.effort')), 'because only the deprecated key the file sets shows').toBeNull();
  await act(async () => { fireEvent.click(within(agents()).getByRole('button', { name: `Clear ${label('jobs.model')}` })); });
  expect(puts, 'because Clear takes the key out of the file').toEqual([{ changes: [{ path: 'jobs.model', value: null }], hash: 'h1' }]);
  expect(said(), 'because the owner sees the key went').toContain(`Saved ${label('jobs.model')}.`);
});

test('AgentsPage_NoClaudeMapAndOldModelSet_ShowsWhatThePluginRunsAndHostDefaultWritesTheMap', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.claude.model', 'jobs.claude.effort'] }) }), withJobs({ model: 'opus' }));
  const model = within(agents()).getByLabelText(label('jobs.claude.model')) as HTMLSelectElement;
  expect(model.value, 'because with no jobs.claude map the plugin falls back to jobs.model, so the jobs run opus').toBe('opus');
  expect(model.closest('.flow-field')!.textContent, 'because the owner must see where that value comes from').toMatch(/now opus, from the deprecated jobs\.model/);
  expect(within(agents()).getByLabelText(label('jobs.claude.effort')).closest('.flow-field')!.textContent, 'because jobs.effort is empty, so nothing is taken from it').not.toMatch(/from the deprecated/);
  fireEvent.change(model, { target: { value: '' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because host default is an empty line in a jobs.claude map, the one thing that ends the fallback').toEqual([{ changes: [{ path: 'jobs.claude.model', value: '' }, { path: 'jobs.claude.effort', value: '' }], hash: 'h1' }]);
});

test('AgentsPage_NoCodexMapAndOldModelSet_ShowsTheMappedName', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ host: 'codex', model: 'opus', effort: 'max' }));
  expect((within(agents()).getByLabelText(label('jobs.codex.model')) as HTMLSelectElement).value, 'because the plugin maps the roster name opus to gpt-6-sol for codex').toBe('gpt-6-sol');
  expect(within(agents()).getByLabelText(label('jobs.codex.model')).closest('.flow-field')!.textContent, 'because the value comes from the old key').toMatch(/now gpt-6-sol, from the deprecated jobs\.model/);
  expect(within(agents()).getByLabelText(label('jobs.codex.effort')).closest('.flow-field')!.textContent, 'because the old effort counts too, even one codex refuses').toMatch(/now max, from the deprecated jobs\.effort/);
});

test('AgentsPage_ClaudeMapPresent_OldModelIgnored', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ model: 'opus', claude: { effort: 'low' } }));
  const model = within(agents()).getByLabelText(label('jobs.claude.model')) as HTMLSelectElement;
  expect([model.value, /from the deprecated/.test(model.closest('.flow-field')!.textContent ?? '')], 'because once jobs.claude is there the plugin reads only it, and its missing model is the host default').toEqual(['', false]);
});

test('AgentsPage_ModelNotInTheList_ShownInOtherAndAnyNameSaves', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.claude.model'] }) }), withJobs({ claude: { model: 'claude-opus-x', effort: 'high' } }));
  expect((within(agents()).getByLabelText(label('jobs.claude.model')) as HTMLSelectElement).selectedOptions[0]!.textContent, 'because the plugin passes any model name on, so one off the list is still a value').toBe('other…');
  const text = within(agents()).getByLabelText(`${label('jobs.claude.model')}, other`) as HTMLInputElement;
  expect(text.value, 'because the text field holds the name the file has').toBe('claude-opus-x');
  fireEvent.change(text, { target: { value: 'claude-opus-y' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because a free name saves as typed, with the effort of the pair').toEqual([{ changes: [{ path: 'jobs.claude.model', value: 'claude-opus-y' }, { path: 'jobs.claude.effort', value: 'high' }], hash: 'h1' }]);
});

test('AgentsPage_OtherPicked_RevealsTheTextFieldAndAListedPickHidesIt', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }));
  const model = within(agents()).getByLabelText(label('jobs.claude.model')) as HTMLSelectElement;
  expect(within(agents()).queryByLabelText(`${label('jobs.claude.model')}, other`), 'because a listed value needs no text field').toBeNull();
  fireEvent.change(model, { target: { value: [...model.options].find((option) => option.textContent === 'other…')!.value } });
  expect(within(agents()).queryByLabelText(`${label('jobs.claude.model')}, other`), 'because other… is for a name off the list').not.toBeNull();
  fireEvent.change(model, { target: { value: 'sonnet' } });
  expect([within(agents()).queryByLabelText(`${label('jobs.claude.model')}, other`), model.value], 'because a listed pick closes it again').toEqual([null, 'sonnet']);
});

test('DeprecatedJobsModel_Cleared_TheFormsOtherEditsStay', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.model'] }) }), withJobs({ model: 'opus' }));
  fireEvent.change(within(group('Retro job')).getByLabelText(label('jobs.marketplace')), { target: { value: '/work/other' } });
  await act(async () => { fireEvent.click(within(agents()).getByRole('button', { name: `Clear ${label('jobs.model')}` })); });
  expect((within(group('Retro job')).getByLabelText(label('jobs.marketplace')) as HTMLInputElement).value, 'because a Clear saves one key and must not throw away what else the owner typed').toBe('/work/other');
  expect(saveButton().disabled, 'because that edit is still to be saved').toBe(false);
});

/** The document with these values beside the fixture's. */
const withValues = (extra: Record<string, unknown>): FlowConfigDocument => ({ ...DOCUMENT, values: { ...DOCUMENT.values, ...extra } });
const ON_GITHUB = { adapters: { default: 'github' } };

function namedGroup(page: string, path: string): HTMLElement {
  return within(group(page)).getByRole('group', { name: label(path) });
}

test('TrackerPage_NoTrackerUsesGithub_GitHubIssueFieldsHiddenWithANote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ github: { limit: 300 } }));
  expect([within(group('Tracker')).queryByLabelText(label('github.limit')), within(group('Tracker')).queryByText(NO_GITHUB)], 'because adapters.default falls back to local, and the GitHub issue keys do nothing while no tracker is GitHub').toEqual([null, expect.anything()]);
  fireEvent.change(within(group('Tracker')).getByLabelText(label('adapters.bug')), { target: { value: 'github' } });
  expect([(within(group('Tracker')).getByLabelText(label('github.limit')) as HTMLInputElement).value, within(group('Tracker')).queryByText(NO_GITHUB)], 'because one kind sent to GitHub is enough for its settings to count').toEqual(['300', null]);
});

test('TrackerPage_NoTrackerUsesGithub_RepositoryStillShows', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ trackers: ['jira'], github: { repo: 'acme/app' } }));
  expect((within(group('Tracker')).getByLabelText(label('github.repo')) as HTMLInputElement).value, 'because the PRs live on GitHub whatever tracker holds the items').toBe('acme/app');
});

test('TrackerPage_NoTrackerUsesJira_JiraPartHiddenWithANote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ jira: { project: 'WID' } }));
  expect([within(group('Tracker')).queryByLabelText(label('jira.project')), within(group('Tracker')).queryByText(NO_JIRA)], 'because the Jira keys do nothing while no tracker is Jira').toEqual([null, expect.anything()]);
});

test('TrackerPage_TrackersNamesJira_JiraFieldsShow', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ trackers: ['jira'], jira: { site: 'https://acme.atlassian.net', project: 'WID' } }));
  expect([(within(group('Tracker')).getByLabelText(label('jira.site')) as HTMLInputElement).value, (within(group('Tracker')).getByLabelText(label('jira.project')) as HTMLInputElement).value, within(group('Tracker')).queryByText(NO_JIRA)], 'because the flow reads Jira while trackers names it, so its site and project are set here').toEqual(['https://acme.atlassian.net', 'WID', null]);
});

test('TrackerPage_TrackersNamesGithub_GitHubPartShows', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ trackers: ['github', 'local'], github: { repo: 'acme/app' } }));
  expect((within(group('Tracker')).getByLabelText(label('github.repo')) as HTMLInputElement).value, 'because the flow reads GitHub issues while trackers names github, though new items default to local').toBe('acme/app');
});

test('TrackerPage_TrackersLeavesGithubOut_GitHubPartHidden', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ ...ON_GITHUB, trackers: ['local'], github: { repo: 'acme/app' } }));
  expect(within(group('Tracker')).queryByText(NO_GITHUB), 'because trackers, not adapters.default, says which trackers the flow reads').not.toBeNull();
});

test('ReadinessPage_NoTrackerUsesGithub_FieldsShow', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), DOCUMENT);
  expect(within(group('Readiness')).queryByRole('group', { name: label('ready.needs') }), 'because the readiness keys apply to the local tracker too').not.toBeNull();
});

test('ReadyNeeds_OnlyTheDeprecatedGithubKeySet_StartsAtItsValue', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ github: { ready_needs: ['size'] } }));
  const needs = namedGroup('Readiness', 'ready.needs');
  expect([(within(needs).getByRole('checkbox', { name: 'priority' }) as HTMLInputElement).checked, (within(needs).getByRole('checkbox', { name: 'size' }) as HTMLInputElement).checked], 'because the flow reads github.ready_needs while ready.needs is unset, so the form shows what it runs with').toEqual([false, true]);
});

test('ReadyNeeds_SavedEmptyBesideTheDeprecatedGithubKey_StartsWithNothingTicked', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues({ ready: { needs: {} }, github: { ready_needs: ['size'] } }));
  const needs = namedGroup('Readiness', 'ready.needs');
  expect([(within(needs).getByRole('checkbox', { name: 'priority' }) as HTMLInputElement).checked, (within(needs).getByRole('checkbox', { name: 'size' }) as HTMLInputElement).checked], 'because an empty ready.needs in the file is what the flow runs with, not the deprecated github.ready_needs').toEqual([false, false]);
});

test('Pages_Read_FieldsUnderTheirPartsHeadings', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues(ON_GITHUB));
  const parts = (page: string): string[] => within(group(page)).getAllByRole('region').map((region) => region.getAttribute('aria-label') ?? '');
  expect([parts('Tracker'), parts('Notifications'), parts('Agents')], 'because a page groups its keys the way the owner thinks of them: where items go, the channels, each AI provider').toEqual([['Where items come from', 'Where new items go', 'GitHub', 'Jira'], ['Channels', 'When to notify'], ['Claude', 'Codex']]);
  const channels = within(group('Notifications')).getByRole('region', { name: 'Channels' });
  expect([within(channels).queryByLabelText(label('notify.desktop')) !== null, within(channels).queryByLabelText(label('notify.slack_webhook')) !== null], 'because desktop banners and Slack are both channels').toEqual([true, true]);
  expect(within(group('Agents')).getByRole('region', { name: 'Claude' }).textContent, 'because the permission mode applies to Claude sessions only').toContain(label('jobs.permission_mode'));
});

test('FreeTextFields_Empty_ShowAConcreteExample', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withValues(ON_GITHUB));
  const placeholder = (page: string, path: string): string | null => within(group(page)).getByLabelText(label(path)).getAttribute('placeholder');
  expect([placeholder('Tracker', 'github.repo'), placeholder('Worktree pool', 'worktree_setup'), placeholder('Readiness', 'ready.priority_order'), placeholder('Intake job', 'intake.notes')], 'because an example says what the key takes better than its type').toEqual(['acme/app', 'npm ci', 'P0\nP1\nP2', '.flow/notes.md']);
  expect(within(group('Notifications')).getByLabelText(label('notify.slack_webhook')).closest('.flow-field')!.textContent, 'because the URL belongs in an environment variable, not in the committed file').toMatch(/FLOW_SLACK_WEBHOOK environment variable first.*only the fallback/);
});

test('FixedKeyMap_BoxEdited_SavesOnlyTheFilledNames', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['github.status'] }) }), withValues({ ...ON_GITHUB, github: { status: { gate: 'Blocked' } } }));
  const status = namedGroup('Tracker', 'github.status');
  const gate = within(status).getByLabelText('Waiting on you (a gate)') as HTMLInputElement;
  const ready = within(status).getByLabelText('Ready') as HTMLInputElement;
  expect([gate.value, ready.value, ready.placeholder], 'because each name has its own box, an empty one showing the flow\'s default').toEqual(['Blocked', '', 'Ready']);
  fireEvent.change(ready, { target: { value: 'Todo' } });
  fireEvent.change(gate, { target: { value: '' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because an empty box leaves its name out of the map').toEqual([{ changes: [{ path: 'github.status', value: { ready: 'Todo' } }], hash: 'h1' }]);
});

test('FixedKeyMap_NameTheFlowDoesNotRead_SaveWaitsForItsRemove', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['github.fields'] }) }), withValues({ ...ON_GITHUB, github: { fields: { size: 'Size', team: 'Team' } } }));
  const fields = namedGroup('Tracker', 'github.fields');
  fireEvent.change(within(fields).getByLabelText('Priority field'), { target: { value: 'Priority' } });
  expect(saveButton().disabled, 'because the check refuses a name other than size, priority and area').toBe(true);
  fireEvent.click(within(fields).getByRole('button', { name: 'Remove team' }));
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because once the stray name is gone the map holds only the names the flow reads').toEqual([{ changes: [{ path: 'github.fields', value: { size: 'Size', priority: 'Priority' } }], hash: 'h1' }]);
});

test('FixedValuesList_Read_CheckboxesAndATickAddsTheValue', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['ready.needs'] }) }), withValues({ ready: { needs: ['priority'] } }));
  const needs = namedGroup('Readiness', 'ready.needs');
  const box = (name: string): HTMLInputElement => within(needs).getByRole('checkbox', { name }) as HTMLInputElement;
  expect([box('priority').checked, box('size').checked], 'because the flow knows priority and size only, so each is a tick').toEqual([true, false]);
  fireEvent.click(box('size'));
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because the ticks are the list, in the field\'s order').toEqual([{ changes: [{ path: 'ready.needs', value: ['priority', 'size'] }], hash: 'h1' }]);
});

test('RowsMap_RowAddedAndOneRemoved_SavesTheRowsLeft', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['gates'] }) }), withValues({ gates: { lint: 'npm run lint' } }));
  const gates = namedGroup('Gates and verification', 'gates');
  expect([(within(gates).getByLabelText('Check 1 name') as HTMLInputElement).value, (within(gates).getByLabelText('Check 1 command') as HTMLInputElement).value], 'because each check is a row of its name and its command').toEqual(['lint', 'npm run lint']);
  fireEvent.click(within(gates).getByRole('button', { name: 'Add a check' }));
  const name = within(gates).getByLabelText('Check 2 name') as HTMLInputElement;
  expect([name.value, name.placeholder, (within(gates).getByLabelText('Check 2 command') as HTMLInputElement).placeholder], 'because a new row starts empty with an example of each box').toEqual(['', 'lint', 'npm run lint']);
  fireEvent.change(name, { target: { value: 'test' } });
  fireEvent.change(within(gates).getByLabelText('Check 2 command'), { target: { value: 'npm test' } });
  fireEvent.click(within(gates).getByRole('button', { name: 'Remove check 1' }));
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because the rows left are the map').toEqual([{ changes: [{ path: 'gates', value: { test: 'npm test' } }], hash: 'h1' }]);
});

test('WorkersSwitches_HostsTurnedOnAndOff_LastOneStaysOnWithTheReason', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.workers'] }) }), withJobs({ workers: { claude: '1' } }));
  const workers = namedGroup('Next job', 'jobs.workers');
  const host = (name: string): HTMLInputElement => within(workers).getByRole('switch', { name }) as HTMLInputElement;
  expect([host('claude').checked, host('claude').disabled, host('codex').checked], 'because a split that starts no worker stops the next job, so its one host on cannot go off').toEqual([true, true, false]);
  expect(workers.textContent, 'because the owner sees why the switch will not move').toMatch(/claude stays on: a split that starts no worker stops the next job/);
  fireEvent.click(host('codex'));
  fireEvent.change(within(workers).getByLabelText('codex workers'), { target: { value: '3' } });
  expect(host('claude').disabled, 'because with codex on, claude may go off').toBe(false);
  fireEvent.click(host('claude'));
  expect([host('claude').checked, within(workers).queryByLabelText('claude workers')], 'because a host off has no count, which the plugin reads as none').toEqual([false, null]);
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because a host off is left out of the map').toEqual([{ changes: [{ path: 'jobs.workers', value: { codex: '3' } }], hash: 'h1' }]);
});

test('WorkersSwitches_StopSplitting_TakesTheKeyOut', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.workers'] }) }), withJobs({ workers: '{claude: 2}' }));
  const workers = namedGroup('Next job', 'jobs.workers');
  expect((within(workers).getByLabelText('claude workers') as HTMLInputElement).value, 'because the one-line form the plugin reads shows the same way').toBe('2');
  fireEvent.click(within(workers).getByRole('button', { name: 'Stop splitting' }));
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because without the key each run starts its own workers on its own host').toEqual([{ changes: [{ path: 'jobs.workers', value: null }], hash: 'h1' }]);
});

test('ScheduleBuilder_ReadAndEdited_WritesTheLineBackWithItsOptions', async () => {
  const { puts } = await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({ saved: ['jobs.schedule.next'] }) }));
  const next = schedule('jobs.schedule.next');
  const value = (name: string): string => (within(next).getByLabelText(name) as HTMLInputElement | HTMLSelectElement).value;
  expect([value('Runs'), value('Every'), value('Unit'), value('Host'), value('Workers')], 'because every 30m --workers 2 reads into the timing, the host jobs.host gives and the workers').toEqual(['every', '30', 'm', '', '2']);
  fireEvent.change(within(next).getByLabelText('Runs'), { target: { value: 'weekly' } });
  fireEvent.change(within(next).getByLabelText('Day'), { target: { value: 'sun' } });
  fireEvent.change(within(next).getByLabelText('At'), { target: { value: '07:00' } });
  fireEvent.change(within(next).getByLabelText('Host'), { target: { value: 'codex' } });
  fireEvent.change(within(next).getByLabelText('Effort'), { target: { value: 'high' } });
  await act(async () => { fireEvent.click(saveButton()); });
  expect(puts, 'because the builder writes the line jobs.sh reads: when, the host word, then the options').toEqual([{ changes: [{ path: 'jobs.schedule.next', value: 'weekly sun 07:00 codex --workers 2 --effort high' }], hash: 'h1' }]);
});

test('ScheduleBuilder_LineItCannotHold_FallsBackToTextWithANote', async () => {
  await renderFlowSettings(() => ({ status: HTTP_OK, body: saved({}) }), withJobs({ schedule: { next: 'every 30m --workers 2', retro: 'weekly Sunday 07:00' } }));
  const retro = schedule('jobs.schedule.retro');
  expect([(within(retro).getByLabelText(`${label('jobs.schedule.retro')} as text`) as HTMLInputElement).value, within(retro).queryByLabelText('Runs')], 'because the builder writes the day as sun, so it leaves the line as the owner wrote it').toEqual(['weekly Sunday 07:00', null]);
  expect(retro.textContent, 'because the owner hears why there are no dropdowns').toMatch(/The builder cannot show this schedule whole, so it is edited as text/);
});

test('TwoProjectsMounted_EachLabel_ReachesItsOwnProjectsInput', async () => {
  const daemon = new FakeDaemon();
  const other: FlowConfigDocument = { ...DOCUMENT, values: { ...DOCUMENT.values, base: 'trunk' } };
  daemon.answer('GET', CONFIG, () => ({ status: HTTP_OK, body: DOCUMENT }));
  daemon.answer('GET', '/api/projects/other/plugins/flow/config', () => ({ status: HTTP_OK, body: other }));
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><FlowSettings projectId="project" name="foosbrawl" show="all" /><FlowSettings projectId="other" name="other" show="all" /></Wrapper>);
  await act(async () => {});
  const base = (name: string): string => (within(screen.getByRole('form', { name: `flow settings form for ${name}` })).getByLabelText(label('base')) as HTMLInputElement).value;
  const schedules = (name: string): HTMLElement => within(within(screen.getByRole('form', { name: `flow settings form for ${name}` })).getByRole('group', { name: 'Schedules' })).getByRole('group', { name: label('jobs.schedule.next') });
  expect([base('foosbrawl'), base('other')], 'because every project\'s form stays mounted, so an id shared across them would point the second label at the first project\'s input').toEqual(['main', 'trunk']);
  expect(schedules('other').closest('form')?.getAttribute('aria-label'), 'because a group named through aria-labelledby must find its own project\'s label too').toBe('flow settings form for other');
});

test('RawYaml_Open_AsksTheDaemonToOpenTheFileInTheEditor', async () => {
  const opened: unknown[] = [];
  const daemon = new FakeDaemon();
  daemon.answer('GET', CONFIG, () => ({ status: HTTP_OK, body: DOCUMENT }));
  daemon.answer('POST', '/api/open', (body) => { opened.push(body); return { status: HTTP_OK, body: { opened: DOCUMENT.path, with: 'editor' } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><FlowSettings projectId="project" name="foosbrawl" show="raw" /></Wrapper>);
  await act(async () => {});
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Open' })); });
  expect(opened, 'because the owner may rather edit the whole file in their own editor').toEqual([{ path: DOCUMENT.path, with: 'editor' }]);
});
