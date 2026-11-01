import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test, vi } from 'vitest';
import type { FlowConfigDocument } from '../../daemon/src/plugins/flow/schema.ts';
import { fieldAt, schemaSections } from '../../daemon/src/plugins/flow/schema.ts';
import type { ProjectCheck, SettingsView } from '../../daemon/src/snapshot.ts';
import { OPEN_PATH } from '../src/OpenFileButton.tsx';
import { CHECK_PROJECT_PATH } from '../src/screens/AddProject.tsx';
import { MENU_STORAGE_KEY, parseCommand, Settings, SETTINGS_PATH } from '../src/screens/Settings.tsx';
import { FakeDaemon, HTTP_OK } from './fakeDaemon.tsx';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  window.localStorage.clear();
});

const HTTP_BAD_REQUEST = 400;

const VIEW: SettingsView = {
  configFile: '/home/o/.config/brain-console/config.json', readFromLegacyFile: null, stateDir: '/home/o/.local/state/brain-console', launchd: false,
  projects: { roots: ['/work/projects/foosbrawl'], from: 'file', editable: true, note: null },
  terminal: { value: null, from: 'default', installed: ['ghostty'] },
  port: { value: 7474, from: 'default', saved: null, note: 'The daemon listens on 7474; a new port takes a restart of the daemon.' },
  fileError: null, newerConsole: null,
};

const FLOW: FlowConfigDocument = {
  path: '/work/projects/foosbrawl/.flow/config.yaml', text: 'base: main\n', hash: 'h1', values: { base: 'main' }, sections: schemaSections(), warnings: [], hostDefaults: { codex: null },
};
const BRAIN_FLOW: FlowConfigDocument = { ...FLOW, path: '/work/brain/.flow/config.yaml', text: 'base: dev\n', hash: 'h2', values: { base: 'dev' } };
const FOOSBRAWL = { id: 'foosbrawl', name: 'foosbrawl', root: '/work/projects/foosbrawl' };
const BRAIN = { id: 'brain', name: 'brain', root: '/work/brain' };
const PROJECTS = [FOOSBRAWL];

type Answer = { status: number; body: unknown };
type Routes = { onPut?: (body: unknown) => Answer; onCheck?: (body: unknown) => Answer; onOpen?: (body: unknown) => Answer; projects?: typeof PROJECTS };
type Sent = { puts: unknown[]; checks: unknown[]; opens: unknown[] };

async function renderSettings(view: SettingsView, routes: Routes = {}): Promise<Sent> {
  const daemon = new FakeDaemon();
  const sent: Sent = { puts: [], checks: [], opens: [] };
  daemon.answer('GET', SETTINGS_PATH, () => ({ status: HTTP_OK, body: view }));
  daemon.answer('GET', '/api/projects', () => ({ status: HTTP_OK, body: routes.projects ?? PROJECTS }));
  daemon.answer('GET', '/api/projects/foosbrawl/plugins/flow/config', () => ({ status: HTTP_OK, body: FLOW }));
  daemon.answer('GET', '/api/projects/brain/plugins/flow/config', () => ({ status: HTTP_OK, body: BRAIN_FLOW }));
  daemon.answer('PUT', SETTINGS_PATH, (body) => { sent.puts.push(body); return (routes.onPut ?? (() => ({ status: HTTP_OK, body: view })))(body); });
  daemon.answer('POST', CHECK_PROJECT_PATH, (body) => { sent.checks.push(body); return (routes.onCheck ?? (() => ({ status: HTTP_OK, body: checkOf([]) })))(body); });
  daemon.answer('POST', OPEN_PATH, (body) => { sent.opens.push(body); return (routes.onOpen ?? (() => ({ status: HTTP_OK, body: { opened: '', with: 'finder' } })))(body); });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Settings /></Wrapper>);
  await act(async () => {});
  return sent;
}

/** Opens one page from the menu beside it. */
function open(label: string): void {
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Settings sections' })).getByRole('button', { name: label }));
}

const ALL_CHECKS = ['path', 'exists', 'flow', 'git', 'watched', 'name'] as const;

/** The daemon's check of /work/brain, with the checks a test names failing. */
function checkOf(failing: ProjectCheck['findings'][number]['check'][]): ProjectCheck {
  const findings = ALL_CHECKS.map((check) => ({ check, ok: !failing.includes(check), text: failing.includes(check) ? `${check} is wrong` : `${check} is fine` }));
  const lacksFlow = failing.includes('flow');
  return { root: '/work/brain', id: 'brain', ok: failing.length === 0, error: failing.length === 0 ? null : 'refused', findings, initCommand: lacksFlow ? 'cd /work/brain && claude /flow:init' : null };
}

/** From the Projects page, through the folder step, to the daemon's check of /work/brain. */
async function checkFolder(): Promise<void> {
  open('Projects');
  fireEvent.click(screen.getByRole('button', { name: 'Add a project' }));
  fireEvent.change(screen.getByRole('textbox', { name: 'Project folder' }), { target: { value: ' /work/brain ' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Check the folder' })); });
}

function currentStep(): string | undefined {
  return within(screen.getByRole('list', { name: 'Steps' })).getAllByRole('listitem').find((item) => item.getAttribute('aria-current') === 'step')?.textContent ?? undefined;
}

test('Settings_Read_OpensOnGeneral', async () => {
  await renderSettings(VIEW);
  expect([screen.getByRole('heading', { name: 'Terminal' }), screen.getByRole('heading', { name: 'Daemon' }), screen.getByRole('heading', { name: 'Files' }), screen.queryByRole('list', { name: 'Watched projects' })], 'because General is the first page and the home of the settings that are no one plugin\'s').toEqual([expect.anything(), expect.anything(), expect.anything(), null]);
});

test('Settings_Menu_GeneralProjectsThenPluginsFlowJobsAndAgents', async () => {
  await renderSettings(VIEW);
  const nav = screen.getByRole('navigation', { name: 'Settings sections' });
  const entries = Array.from(nav.querySelectorAll('button')).map((entry) => entry.textContent);
  expect(entries, 'because the menu groups the console pages, the flow plugin\'s pages, the jobs\' pages and the agents\' page').toEqual([
    'General', 'Projects',
    'Plugins', 'Flow', 'Tracker', 'Readiness', 'Worktree pool', 'Gates and verification', 'Reviews', 'Notifications',
    'Jobs', 'Schedules', 'Configuration',
    'Agents',
  ]);
});

/** A menu group's toggle, by its label. */
function groupToggle(label: string): HTMLElement {
  return within(screen.getByRole('navigation', { name: 'Settings sections' })).getByRole('button', { name: label });
}

/** The page links the menu shows now: a closed group's links are out of the accessible tree. */
function visibleLinks(): string[] {
  return within(screen.getByRole('navigation', { name: 'Settings sections' })).queryAllByRole('button').filter((button) => !button.hasAttribute('aria-expanded')).map((button) => button.textContent ?? '');
}

test('SettingsMenu_GroupsAtFirst_AllOpen', async () => {
  await renderSettings(VIEW);
  expect(['Plugins', 'Flow', 'Jobs'].map((label) => groupToggle(label).getAttribute('aria-expanded')), 'because every group opens by default so no page is hidden on a first visit').toEqual(['true', 'true', 'true']);
});

test('SettingsMenu_ToggleClicked_CollapsesThenExpandsItsPages', async () => {
  await renderSettings(VIEW);
  fireEvent.click(groupToggle('Jobs'));
  const collapsed = [groupToggle('Jobs').getAttribute('aria-expanded'), visibleLinks().includes('Schedules'), visibleLinks().includes('Tracker')];
  fireEvent.click(groupToggle('Jobs'));
  expect([collapsed, groupToggle('Jobs').getAttribute('aria-expanded'), visibleLinks().includes('Schedules')], 'because a group hides its own pages when collapsed, leaves the others, and shows them again when expanded').toEqual([['false', false, true], 'true', true]);
});

test('SettingsMenu_PluginsCollapsed_HidesFlowAndItsPages', async () => {
  await renderSettings(VIEW);
  fireEvent.click(groupToggle('Plugins'));
  const nav = screen.getByRole('navigation', { name: 'Settings sections' });
  expect([within(nav).queryByRole('button', { name: 'Flow' }), visibleLinks().includes('Tracker')], 'because Flow sits inside Plugins and goes with it').toEqual([null, false]);
});

test('SettingsMenu_GroupCollapsed_RememberedOnTheNextVisit', async () => {
  await renderSettings(VIEW);
  fireEvent.click(groupToggle('Plugins'));
  cleanup();
  await renderSettings(VIEW);
  expect([groupToggle('Plugins').getAttribute('aria-expanded'), groupToggle('Jobs').getAttribute('aria-expanded'), window.localStorage.getItem(MENU_STORAGE_KEY)], 'because the viewer\'s open and closed groups are kept in this browser').toEqual(['false', 'true', '["plugins"]']);
});

test('SettingsMenu_StorageBlocked_GroupsStillOpenAndClose', async () => {
  vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked'); });
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked'); });
  await renderSettings(VIEW);
  const opened = groupToggle('Jobs').getAttribute('aria-expanded');
  fireEvent.click(groupToggle('Jobs'));
  expect([opened, groupToggle('Jobs').getAttribute('aria-expanded')], 'because blocked storage only means the state is not remembered').toEqual(['true', 'false']);
});

test('SettingsMenu_CurrentPagesGroup_StaysOpen', async () => {
  await renderSettings(VIEW);
  open('Tracker');
  fireEvent.click(groupToggle('Plugins'));
  fireEvent.click(groupToggle('Flow'));
  open('Configuration');
  fireEvent.click(groupToggle('Jobs'));
  expect([groupToggle('Plugins').getAttribute('aria-expanded'), groupToggle('Jobs').getAttribute('aria-expanded'), visibleLinks().includes('Configuration')], 'because the group holding the page on screen cannot hide that page\'s link').toEqual(['true', 'true', true]);
});

test('SettingsMenu_JobsGroup_SchedulesAndConfigurationOnly', async () => {
  await renderSettings(VIEW);
  const body = document.getElementById(groupToggle('Jobs').getAttribute('aria-controls') ?? '')!;
  expect(within(body).getAllByRole('button').map((button) => button.textContent), 'because the jobs\' own settings live in Configuration, one tab each').toEqual(['Schedules', 'Configuration']);
});

/** The job tabs on the Configuration page. */
function jobTab(label: string): HTMLElement {
  return within(screen.getByRole('group', { name: 'Jobs' })).getByRole('button', { name: label });
}

function currentJobTab(): string | null {
  return within(screen.getByRole('group', { name: 'Jobs' })).getAllByRole('button').find((button) => button.getAttribute('aria-current') === 'true')?.textContent ?? null;
}

test('Configuration_Opened_TrailWithATabPerJob', async () => {
  await renderSettings(VIEW);
  open('Configuration');
  await act(async () => {});
  const trail = screen.getByRole('navigation', { name: 'Job configuration' });
  expect([trail.textContent?.startsWith('Configuration›'), within(trail).getAllByRole('button').map((button) => button.textContent), currentJobTab()], 'because the page names itself, then offers one button per job with the first chosen').toEqual([true, ['Next', 'Health', 'Comments', 'Retro', 'Intake'], 'Next']);
});

test('Configuration_Opened_ShowsOneJobAtATime', async () => {
  await renderSettings(VIEW);
  open('Configuration');
  await act(async () => {});
  const shown = ['Next job', 'Health job', 'Comments job', 'Retro job', 'Intake job', 'Schedules'].map((group) => screen.queryByRole('heading', { name: group }) !== null);
  expect(shown, 'because only the chosen job\'s settings show').toEqual([true, false, false, false, false, false]);
});

test('Configuration_JobButton_SwitchesTheJobShown', async () => {
  await renderSettings(VIEW);
  open('Configuration');
  await act(async () => {});
  fireEvent.click(jobTab('Health'));
  expect([screen.queryByRole('heading', { name: 'Health job' }) !== null, screen.queryByRole('heading', { name: 'Next job' }), currentJobTab()], 'because a job button shows that job instead of the one before').toEqual([true, null, 'Health']);
});

test('Configuration_DraftOnAJobTab_SurvivesSwitchingTabsAndPages', async () => {
  await renderSettings(VIEW);
  open('Configuration');
  await act(async () => {});
  fireEvent.click(jobTab('Health'));
  const label = fieldAt('jobs.health.max_resumes')!.label;
  fireEvent.change(screen.getByLabelText(label), { target: { value: '5' } });
  fireEvent.click(jobTab('Next'));
  fireEvent.click(jobTab('Health'));
  const afterTabs = (screen.getByLabelText(label) as HTMLInputElement).value;
  fireEvent.click(jobTab('Comments'));
  open('General');
  open('Configuration');
  const tabAfterPages = currentJobTab();
  fireEvent.click(jobTab('Health'));
  expect([afterTabs, tabAfterPages, (screen.getByLabelText(label) as HTMLInputElement).value], 'because each job\'s form stays mounted and the chosen job is kept while the owner moves between pages').toEqual(['5', 'Comments', '5']);
});

test('Settings_OneProject_NoProjectPicker', async () => {
  await renderSettings(VIEW);
  expect(screen.queryByRole('combobox'), 'because with one project there is nothing to pick').toBeNull();
});

/** The flow page on screen: hidden pages of the other project stay mounted but out of the accessible tree. */
function shownFlowPage(group: string): HTMLElement {
  return screen.getByRole('heading', { name: group }).closest<HTMLElement>('.module')!;
}

test('Settings_TwoProjects_ThePickerScopesTheFlowPages', async () => {
  await renderSettings(VIEW, { projects: [FOOSBRAWL, BRAIN] });
  open('Worktree pool');
  await act(async () => {});
  const before = within(shownFlowPage('Worktree pool')).queryByDisplayValue('main') !== null;
  fireEvent.change(screen.getByRole('combobox', { name: /Project for/ }), { target: { value: 'brain' } });
  const page = shownFlowPage('Worktree pool');
  expect([before, within(page).queryByDisplayValue('dev') !== null, within(page).queryByDisplayValue('main'), page.textContent], 'because the page shows the picked project\'s .flow/config.yaml and no other').toEqual([true, true, null, expect.stringMatching(/brain · \.flow\/config\.yaml/)]);
});

test('Settings_TwoProjects_ADraftSurvivesSwitchingTheProject', async () => {
  await renderSettings(VIEW, { projects: [FOOSBRAWL, BRAIN] });
  open('Worktree pool');
  await act(async () => {});
  fireEvent.change(within(shownFlowPage('Worktree pool')).getByDisplayValue('main'), { target: { value: 'release' } });
  const picker = screen.getByRole('combobox', { name: /Project for/ });
  fireEvent.change(picker, { target: { value: 'brain' } });
  fireEvent.change(picker, { target: { value: 'foosbrawl' } });
  expect(within(shownFlowPage('Worktree pool')).queryByDisplayValue('release'), 'because each project\'s form stays mounted while another shows').not.toBeNull();
});

test('Settings_General_ListsEachFileWithShowInFinder', async () => {
  await renderSettings(VIEW);
  const files = screen.getByRole('heading', { name: 'Files' }).closest('section')!;
  const paths = [VIEW.configFile, VIEW.stateDir, '/work/projects/foosbrawl/.flow/config.yaml'].map((path) => within(files).queryByText(path) !== null);
  expect([paths, within(files).getAllByRole('button', { name: 'Show in Finder' }).length], 'because the owner may want a file by hand and should find each in one place').toEqual([[true, true, true], 3]);
});

test('Settings_General_HoldsEachProjectsRawYaml', async () => {
  await renderSettings(VIEW);
  expect(screen.getByRole('heading', { name: 'foosbrawl: raw YAML' }), 'because the raw files sit under General with the other files').not.toBeNull();
});

test('Settings_ShowInFinder_AsksTheDaemonForThatFile', async () => {
  const sent = await renderSettings(VIEW);
  await act(async () => { fireEvent.click(within(screen.getByText(VIEW.stateDir).closest('dd')!).getByRole('button', { name: 'Show in Finder' })); });
  expect(sent.opens, 'because the daemon opens only the files it knows, named by their path').toEqual([{ path: VIEW.stateDir, with: 'finder' }]);
});

test('OpenFileButton_Refused_ShowsTheReason', async () => {
  await renderSettings(VIEW, { onOpen: () => ({ status: 501, body: { error: 'opening a file needs macOS (the open command); this daemon runs on linux' } }) });
  await act(async () => { fireEvent.click(within(screen.getByText(VIEW.configFile).closest('dd')!).getByRole('button', { name: 'Show in Finder' })); });
  expect(screen.getByRole('status').textContent, 'because a button that does nothing must say why').toMatch(/needs macOS/);
});

test('Settings_FlowEditThenGeneralAndBack_TheEditWaits', async () => {
  await renderSettings(VIEW);
  open('Worktree pool');
  await act(async () => {});
  fireEvent.change(screen.getByLabelText(fieldAt('base')!.label), { target: { value: 'dev' } });
  open('General');
  open('Schedules');
  open('Agents');
  open('Worktree pool');
  expect((screen.getByLabelText(fieldAt('base')!.label) as HTMLInputElement).value, 'because moving between pages must not throw away what the owner typed').toBe('dev');
});

test('Settings_RemoveProject_PutsTheListWithoutIt', async () => {
  const sent = await renderSettings({ ...VIEW, projects: { ...VIEW.projects, roots: ['/a', '/b'] } });
  open('Projects');
  await act(async () => { fireEvent.click(screen.getAllByRole('button', { name: 'Remove' })[0]!); });
  expect(sent.puts, 'because a removed root stops being watched').toEqual([{ projects: [{ root: '/b' }] }]);
});

test('Settings_ProjectsFromAFlag_NoAddOrRemoveAndTheNoteSaysWhy', async () => {
  await renderSettings({ ...VIEW, projects: { roots: ['/work/projects/foosbrawl'], from: 'flag', editable: false, note: 'Set by --project when the daemon started; start it without the flag to edit them here.' } });
  open('Projects');
  expect([screen.queryByRole('button', { name: 'Add a project' }), screen.queryByRole('button', { name: 'Remove' })], 'because a flag would bring the list back on the next start').toEqual([null, null]);
  expect(screen.queryByText(/Set by --project/), 'because the owner hears why the list is locked').not.toBeNull();
});

test('AddProject_FolderStep_ChecksTheTypedFolder', async () => {
  const sent = await renderSettings(VIEW);
  await checkFolder();
  expect([sent.checks, currentStep()], 'because the daemon checks the folder as typed, trimmed, before anything is saved').toEqual([[{ root: '/work/brain' }], '2. Check']);
});

test('AddProject_CheckStep_EachFindingShownAndNextOnlyWhenAllPass', async () => {
  await renderSettings(VIEW, { onCheck: () => ({ status: HTTP_OK, body: checkOf(['name']) }) });
  await checkFolder();
  const items = within(screen.getByRole('list', { name: 'Checks' })).getAllByRole('listitem');
  expect([items.length, items.at(-1)?.textContent, screen.getByRole('button', { name: 'Next' }).hasAttribute('disabled')], 'because the owner sees every check and cannot go on past a failed one').toEqual([6, expect.stringMatching(/name is wrong/), true]);
});

test('AddProject_NoFlowConfig_ShowsTheInitCommandThenCheckAgainPasses', async () => {
  let answer = checkOf(['flow']);
  const sent = await renderSettings(VIEW, { onCheck: () => ({ status: HTTP_OK, body: answer }) });
  await checkFolder();
  const command = screen.getByLabelText('flow:init command').textContent;
  answer = checkOf([]);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Check again' })); });
  expect([command, sent.checks.length, screen.queryByLabelText('flow:init command'), screen.getByRole('button', { name: 'Next' }).hasAttribute('disabled')], 'because the owner runs flow:init in the folder, checks again, and goes on once it passes').toEqual(['cd /work/brain && claude /flow:init', 2, null, false]);
});

test('AddProject_Confirm_ShowsTheNameAndRootThenPutsTheWholeList', async () => {
  const sent = await renderSettings(VIEW);
  await checkFolder();
  fireEvent.click(screen.getByRole('button', { name: 'Next' }));
  const facts = screen.getByRole('button', { name: 'Add brain' }).closest('.wizard-body')?.textContent;
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add brain' })); });
  expect([facts, sent.puts], 'because the owner confirms the name and root, and the daemon gets the watched list with the root it resolved').toEqual([expect.stringMatching(/Namebrain.*Root\/work\/brain/), [{ projects: [{ root: '/work/projects/foosbrawl' }, { root: '/work/brain' }] }]]);
});

test('AddProject_Done_LinksToTheNewProjectsOverview', async () => {
  await renderSettings(VIEW);
  await checkFolder();
  fireEvent.click(screen.getByRole('button', { name: 'Next' }));
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add brain' })); });
  expect([currentStep(), screen.getByRole('link', { name: 'Open the brain overview' }).getAttribute('href')], 'because once it is watched the owner goes straight to it').toEqual(['4. Done', '#/brain/overview']);
});

test('AddProject_PutRefused_StaysOnConfirmAndSaysWhy', async () => {
  await renderSettings(VIEW, { onPut: () => ({ status: HTTP_BAD_REQUEST, body: { error: '/work/brain has no .flow/config.yaml; run flow:init there first' } }) });
  await checkFolder();
  fireEvent.click(screen.getByRole('button', { name: 'Next' }));
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add brain' })); });
  expect([currentStep(), screen.getByRole('alert').textContent], 'because a refused add must say what the folder lacks, and leave the owner where they were').toEqual(['3. Confirm', expect.stringMatching(/no \.flow\/config\.yaml/)]);
});

test('Settings_PickATerminal_SavedAtOnce', async () => {
  const { puts } = await renderSettings(VIEW);
  await act(async () => { fireEvent.click(screen.getByRole('radio', { name: /^iTerm/ })); });
  expect(puts, 'because a named terminal needs nothing more').toEqual([{ terminal: 'iterm' }]);
});

test('Settings_NoTerminalSet_SaysWhichOneOpens', async () => {
  await renderSettings(VIEW);
  expect(screen.getByRole('radio', { name: /first installed/ }).closest('label')?.textContent, 'because the default picks the first installed app and the owner should know which').toMatch(/\(Ghostty\)/);
});

test('Settings_CustomCommandWithASpaceInAWord_SavedWhole', async () => {
  const { puts } = await renderSettings(VIEW);
  fireEvent.click(screen.getByRole('radio', { name: 'Custom command' }));
  fireEvent.change(screen.getByRole('textbox', { name: 'Command as a JSON array' }), { target: { value: '["open", "-a", "/Applications/My Term.app", "{path}"]' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Save' })); });
  expect(puts, 'because an app path with a space is one word, and the daemon runs the array without a shell').toEqual([{ terminal: { command: ['open', '-a', '/Applications/My Term.app', '{path}'] } }]);
});

test('Settings_CustomCommandNotAnArray_SaveDisabledWithTheReason', async () => {
  await renderSettings(VIEW);
  fireEvent.click(screen.getByRole('radio', { name: 'Custom command' }));
  fireEvent.change(screen.getByRole('textbox', { name: 'Command as a JSON array' }), { target: { value: 'open -a Warp' } });
  expect([screen.getByRole('button', { name: 'Save' }).hasAttribute('disabled'), screen.getByRole('status').textContent], 'because plain words cannot say where a word with a space ends').toEqual([true, expect.stringMatching(/JSON array/)]);
});

test('ParseCommand_EmptyWord_Refused', () => {
  expect(parseCommand('["open", ""]').ok, 'because an empty word is refused before it is sent, as the daemon would').toBe(false);
});

test('Settings_Port_SavedForTheNextStartWithTheNote', async () => {
  const { puts } = await renderSettings(VIEW);
  fireEvent.change(screen.getByRole('textbox', { name: 'Port for the next start' }), { target: { value: '7480' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Save for the next start' })); });
  expect([puts, screen.queryByText(/takes a restart/)], 'because the daemon listens on its port until it starts again').toEqual([[{ port: 7480 }], expect.anything()]);
});

test('Settings_PortOutOfRange_SaveDisabled', async () => {
  await renderSettings(VIEW);
  fireEvent.change(screen.getByRole('textbox', { name: 'Port for the next start' }), { target: { value: '70000' } });
  expect(screen.getByRole('button', { name: 'Save for the next start' }).hasAttribute('disabled'), 'because no port is above 65535').toBe(true);
});

test('Settings_UnderLaunchd_SaysSo', async () => {
  await renderSettings({ ...VIEW, launchd: true });
  expect(screen.queryByText(/launchd: it starts on login/), 'because the owner should know whether the daemon comes back by itself').not.toBeNull();
});
