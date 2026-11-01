import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config.ts';
import type { DaemonConfig } from '../src/config.ts';
import type { ProjectDefinition } from '../src/project.ts';
import { fileStamp, SELF_CHECK_MS, SelfCheck } from '../src/selfCheck.ts';
import { SettingsStore } from '../src/settings.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';
import { fakeScheduler } from './fakeSpawner.ts';

const LOCAL_ROOT = path.join(FIXTURES, 'project-local');

/** A store over a config read from a fresh folder, with the files and arguments a test names. */
function store(argv: string[], files: Record<string, unknown>) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-settings-'));
  for (const [name, content] of Object.entries(files)) writeFileSync(path.join(dir, name), JSON.stringify(content));
  const paths = { configFile: path.join(dir, 'config.json'), legacyProjectsFile: path.join(dir, 'projects.json') };
  const read = readConfig(argv, { BRAIN_CONSOLE_TOKEN: 't', BRAIN_CONSOLE_STATE: dir }, paths);
  assert.ok(read.ok, 'because the test config is valid');
  const config = (read as { config: DaemonConfig }).config;
  const applied: ProjectDefinition[][] = [];
  const settings = new SettingsStore({ config, installed: () => ['ghostty', 'terminal'], applyProjects: (projects) => applied.push(projects), newerConsole: () => null });
  const written = (): unknown => JSON.parse(readFileSync(paths.configFile, 'utf8'));
  return { settings, applied, written, paths, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

const FILE_PROJECT = { 'config.json': { projects: [{ root: FIXTURE_ROOT }] } };

test('View_FileProjects_EachSettingSaysWhereItCameFrom', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  try {
    const view = settings.view();
    assert.deepEqual([view.projects.from, view.projects.editable, view.terminal.from, view.port.from, view.port.value], ['file', true, 'default', 'default', 7474], 'because the owner must see which settings the file holds and which are defaults');
    assert.equal(view.configFile, paths.configFile, 'because the screen shows the file to edit by hand');
    assert.deepEqual(view.terminal.installed, ['ghostty', 'terminal'], 'because with no terminal set the first installed one opens');
  } finally { cleanup(); }
});

test('Projects_FromAFlag_NotEditableWithTheReason', () => {
  const { settings, cleanup } = store(['--project', FIXTURE_ROOT], {});
  try {
    const view = settings.view();
    assert.deepEqual([view.projects.from, view.projects.editable], ['flag', false], 'because a restart would bring the flag back over any edit');
    assert.match(view.projects.note ?? '', /--project/, 'because the screen says why the list is locked');
    const refused = settings.update({ projects: [{ root: LOCAL_ROOT }] });
    assert.equal(refused.ok, false, 'because projects set by a flag cannot change from Settings');
  } finally { cleanup(); }
});

test('PutProjects_TwoValidRoots_WrittenAndAppliedLive', () => {
  const { settings, applied, written, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] });
    assert.ok(result.ok, 'because both roots hold a flow');
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project', 'project-local']], 'because the daemon starts watching the new root without a restart');
    assert.deepEqual(written(), { projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }, 'because the file is what the next start reads');
  } finally { cleanup(); }
});

test('PutProjects_RootWithoutFlow_RefusedAndNothingWritten', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ projects: [{ root: path.join(FIXTURES, 'project-wt-2') }] });
    assert.match(result.ok ? '' : result.error, /no \.flow\/config\.yaml/, 'because a root must hold .flow/config.yaml, and the reason says so');
    assert.deepEqual([applied.length, existsSync(paths.configFile)], [0, true], 'because a refused change leaves the running list and the file as they were');
  } finally { cleanup(); }
});

test('PutProjects_RelativeRoot_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ projects: [{ root: 'projects/foo' }] }).ok, false, 'because a relative root would depend on where the daemon was started');
  } finally { cleanup(); }
});

test('PutProjects_EmptyList_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ projects: [] }).ok, false, 'because a daemon that watches nothing could not start again');
  } finally { cleanup(); }
});

test('PutTerminal_Command_KeptOtherSettingsUntouched', () => {
  const { settings, written, cleanup } = store([], FILE_PROJECT);
  try {
    assert.ok(settings.update({ terminal: { command: ['open', '-a', 'Warp', '{path}'] } }).ok, 'because a non-empty command array is a terminal');
    assert.deepEqual(written(), { projects: [{ root: FIXTURE_ROOT }], terminal: { command: ['open', '-a', 'Warp', '{path}'] } }, 'because a PUT changes only what it names');
    assert.deepEqual(settings.terminal(), { command: ['open', '-a', 'Warp', '{path}'] }, 'because the next Open in Terminal uses it without a restart');
  } finally { cleanup(); }
});

test('PutTerminal_BadValue_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    for (const terminal of ['kitty', { command: [] }, { command: ['open', ''] }, ['open']]) {
      assert.equal(settings.update({ terminal }).ok, false, `because ${JSON.stringify(terminal)} is neither a known terminal nor a non-empty command`);
    }
  } finally { cleanup(); }
});

test('PutTerminal_Null_BackToTheFirstInstalled', () => {
  const { settings, written, cleanup } = store([], { 'config.json': { projects: [{ root: FIXTURE_ROOT }], terminal: 'iterm' } });
  try {
    settings.update({ terminal: null });
    assert.deepEqual([settings.terminal(), settings.view().terminal.from, written()], [null, 'default', { projects: [{ root: FIXTURE_ROOT }] }], 'because clearing the choice goes back to picking the first installed app');
  } finally { cleanup(); }
});

test('PutPort_NewPort_SavedButTheDaemonKeepsItsPort', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ port: 7480 });
    assert.ok(result.ok, 'because 7480 is a port');
    assert.deepEqual([result.value.port.value, result.value.port.saved], [7474, 7480], 'because a new port only takes effect after a restart');
    assert.match(result.value.port.note, /restart/, 'because the screen says so');
  } finally { cleanup(); }
});

test('Put_UnknownSetting_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ temrinal: 'iterm' }).ok, false, 'because a typo must not be written and then ignored');
  } finally { cleanup(); }
});

test('LegacyProjectsFile_OnlyFile_NotedUntilTheFirstWrite', () => {
  const { settings, written, cleanup } = store([], { 'projects.json': { projects: [{ root: FIXTURE_ROOT }] } });
  try {
    assert.match(settings.view().readFromLegacyFile ?? '', /projects\.json$/, 'because the screen says where the projects came from');
    settings.update({ terminal: 'ghostty' });
    assert.deepEqual([settings.view().readFromLegacyFile, written()], [null, { projects: [{ root: FIXTURE_ROOT }], terminal: 'ghostty' }], 'because the first save moves the projects into config.json');
  } finally { cleanup(); }
});

test('Put_FileEditedByHandSinceTheStart_EditKept', () => {
  const { settings, written, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }], port: 7490 }));
    settings.update({ terminal: 'ghostty' });
    assert.deepEqual(written(), { projects: [{ root: FIXTURE_ROOT }], port: 7490, terminal: 'ghostty' }, 'because a save from the screen must not undo what the owner wrote in the file meanwhile');
  } finally { cleanup(); }
});

test('Put_FileBrokenByHand_RefusedAndLeftAsItIs', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, '{"projects": [');
    const result = settings.update({ terminal: 'ghostty' });
    assert.match(result.ok ? '' : result.error, /not valid JSON/, 'because the owner hears why nothing was saved');
    assert.equal(readFileSync(paths.configFile, 'utf8'), '{"projects": [', 'because a half-written hand edit is the owner\'s to finish, not ours to overwrite');
  } finally { cleanup(); }
});

test('PutPort_PortFromAFlag_NoteSaysTheFlagWins', () => {
  const { settings, cleanup } = store(['--port', '7475'], FILE_PROJECT);
  try {
    const result = settings.update({ port: 7480 });
    assert.match(result.ok ? result.value.port.note : '', /set by --port: a port saved here is used only when it starts without --port/, 'because a saved port has no effect while the flag sets it, and the owner must not wait for it');
  } finally { cleanup(); }
});

/** A fresh folder named `name` that holds what a test names: a .flow/config.yaml, a .git, or both. */
function folder(name: string, parts: { flow: boolean; git: boolean }): string {
  const root = path.join(mkdtempSync(path.join(os.tmpdir(), 'console-check-')), name);
  mkdirSync(root, { recursive: true });
  if (parts.flow) { mkdirSync(path.join(root, '.flow')); writeFileSync(path.join(root, '.flow', 'config.yaml'), 'base: main\n'); }
  if (parts.git) mkdirSync(path.join(root, '.git'));
  return root;
}

test('CheckProject_FolderWithAFlowInGit_EveryFindingOkAndNoCommand', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    const check = settings.checkProject(LOCAL_ROOT);
    assert.deepEqual(check.findings.map((finding) => [finding.check, finding.ok]), [['path', true], ['exists', true], ['flow', true], ['git', true], ['watched', true], ['name', true]], 'because the fixture folder exists, holds a flow, sits in this repository and is not watched yet');
    assert.deepEqual([check.ok, check.error, check.id, check.root, check.initCommand], [true, null, 'project-local', LOCAL_ROOT, null], 'because the PUT would take it under its folder name');
  } finally { cleanup(); }
});

test('CheckProject_NoFlowConfig_FlowFindingFailsWithTheInitCommand', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  const root = folder('fresh repo', { flow: false, git: true });
  try {
    const check = settings.checkProject(root);
    assert.deepEqual(check.findings.filter((finding) => !finding.ok).map((finding) => finding.check), ['flow'], 'because only the .flow/config.yaml is missing');
    assert.equal(check.initCommand, `cd '${root}' && claude /flow:init`, 'because the owner gets the line to run there, the folder quoted for its space');
    assert.match(check.error ?? '', /run flow:init there first/, 'because the refusal is the PUT\'s own words');
  } finally { cleanup(); rmSync(path.dirname(root), { recursive: true, force: true }); }
});

test('CheckProject_MissingFolder_OnlyThePathAndExistsFindings', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    const check = settings.checkProject('/nowhere/at/all');
    assert.deepEqual(check.findings.map((finding) => [finding.check, finding.ok]), [['path', true], ['exists', false]], 'because nothing more can be said of a folder that is not there');
  } finally { cleanup(); }
});

test('CheckProject_AndThePut_AgreeOnEveryKindOfFolder', () => {
  const made = [folder('outside-git', { flow: true, git: false }), folder('project', { flow: true, git: true }), folder('no-flow', { flow: false, git: true })];
  const cases: unknown[] = [LOCAL_ROOT, FIXTURE_ROOT, '/nowhere/at/all', 'relative/path', path.join(FIXTURES, 'project-wt-2'), path.join(FIXTURE_ROOT, '.flow', 'config.yaml'), ...made];
  try {
    for (const root of cases) {
      const checked = store([], FILE_PROJECT);
      const put = store([], FILE_PROJECT);
      try {
        const check = checked.settings.checkProject(root);
        const update = put.settings.update({ projects: [{ root: FIXTURE_ROOT }, { root }] });
        assert.deepEqual([check.ok, check.error], [update.ok, update.ok ? null : update.error], `because the check and the PUT must give ${String(root)} the same answer`);
        assert.equal(check.ok, check.findings.every((finding) => finding.ok), `because a failed finding for ${String(root)} is a refused PUT, and a refused PUT shows a failed finding`);
      } finally { checked.cleanup(); put.cleanup(); }
    }
  } finally { for (const root of made) rmSync(path.dirname(root), { recursive: true, force: true }); }
});

test('CheckProject_AlreadyWatchedAndNameClash_EachSaysWhich', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  const twin = folder('project', { flow: true, git: true });
  try {
    const watched = settings.checkProject(FIXTURE_ROOT).findings.find((finding) => !finding.ok);
    const clash = settings.checkProject(twin).findings.find((finding) => !finding.ok);
    assert.deepEqual([watched?.check, clash?.check], ['watched', 'name'], 'because the same root and another root under the same folder name are told apart');
    assert.match(clash?.text ?? '', new RegExp(`${FIXTURE_ROOT}.*also called project`), 'because the owner hears which watched project has the name');
  } finally { cleanup(); rmSync(path.dirname(twin), { recursive: true, force: true }); }
});

test('CheckProject_ProjectsFromAFlag_RefusedAsThePutIs', () => {
  const { settings, cleanup } = store(['--project', FIXTURE_ROOT], {});
  try {
    const check = settings.checkProject(LOCAL_ROOT);
    assert.deepEqual([check.ok, check.error], [false, (settings.update({ projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }) as { error: string }).error], 'because a flag would bring the list back, so neither the check nor the PUT takes a new root');
  } finally { cleanup(); }
});

test('PutProjects_FolderOutsideGit_RefusedWithTheReason', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  const root = folder('loose', { flow: true, git: false });
  try {
    const result = settings.update({ projects: [{ root: FIXTURE_ROOT }, { root }] });
    assert.match(result.ok ? '' : result.error, /not in a git checkout/, 'because the flow works on branches and worktrees, which a folder outside git has none of');
  } finally { cleanup(); rmSync(path.dirname(root), { recursive: true, force: true }); }
});

const BOTH_PROJECTS = { projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] };

test('Reload_ProjectAddedByHand_Applied', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, JSON.stringify(BOTH_PROJECTS));
    settings.reload();
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project', 'project-local']], 'because a root added to the file by hand is watched without a restart');
  } finally { cleanup(); }
});

test('Reload_ProjectRemovedByHand_Dropped', () => {
  const { settings, applied, paths, cleanup } = store([], { 'config.json': BOTH_PROJECTS });
  try {
    writeFileSync(paths.configFile, JSON.stringify({ projects: [{ root: LOCAL_ROOT }] }));
    settings.reload();
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project-local']], 'because a root taken out of the file by hand stops being watched');
  } finally { cleanup(); }
});

test('Reload_FileNotJson_KeepsTheProjectsItLoaded', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, '{"projects": [');
    settings.reload();
    assert.deepEqual([applied.length, settings.view().projects.roots], [0, [FIXTURE_ROOT]], 'because a half-written file must not stop the daemon watching what it watches');
  } finally { cleanup(); }
});

test('Reload_FileNotJson_ViewSaysWhy', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, '{"projects": [');
    settings.reload();
    assert.match(settings.view().fileError ?? '', /not valid JSON/, 'because status must say the file differs from what the daemon loaded, and why');
  } finally { cleanup(); }
});

test('Reload_RelativeRoot_RefusedWithTheReason', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, JSON.stringify({ projects: [{ root: 'projects/foo' }] }));
    settings.reload();
    assert.deepEqual([applied.length, /absolute path/.test(settings.view().fileError ?? '')], [0, true], 'because a file that fails the checks is refused as a PUT would be, with the check\'s words');
  } finally { cleanup(); }
});

test('Reload_FixedAfterARefusal_NoErrorLeft', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, '{"projects": [');
    settings.reload();
    writeFileSync(paths.configFile, JSON.stringify(BOTH_PROJECTS));
    settings.reload();
    assert.equal(settings.view().fileError, null, 'because once the daemon took the file there is no difference left to report');
  } finally { cleanup(); }
});

test('Reload_ProjectsFromAFlag_StayFixed', () => {
  const { settings, applied, paths, cleanup } = store(['--project', FIXTURE_ROOT], {});
  try {
    writeFileSync(paths.configFile, JSON.stringify({ projects: [{ root: LOCAL_ROOT }] }));
    settings.reload();
    assert.deepEqual([applied.length, settings.view().projects.roots], [0, [FIXTURE_ROOT]], 'because projects given by a flag stay fixed while the daemon runs');
  } finally { cleanup(); }
});

test('Reload_AfterTheDaemonsOwnSave_NothingToTake', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    settings.update({ terminal: 'ghostty', port: 7490 });
    assert.equal(settings.reload(), null, 'because a file the daemon wrote itself holds what it runs, so there is no reload to log');
  } finally { cleanup(); }
});

test('Reload_ProjectAddedByHandThenTerminalSaved_Applied', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    writeFileSync(paths.configFile, JSON.stringify(BOTH_PROJECTS));
    settings.update({ terminal: 'ghostty' });
    settings.reload();
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project', 'project-local']], 'because a save of another setting before the next look keeps the hand-added root in the file, and it must still be watched');
  } finally { cleanup(); }
});

test('Reload_ProjectRemovedByHandThenPortSaved_Dropped', () => {
  const { settings, applied, paths, cleanup } = store([], { 'config.json': BOTH_PROJECTS });
  try {
    writeFileSync(paths.configFile, JSON.stringify({ projects: [{ root: LOCAL_ROOT }] }));
    settings.update({ port: 7490 });
    settings.reload();
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project-local']], 'because a save of another setting before the next look keeps the hand-removed root out of the file, and it must stop being watched');
  } finally { cleanup(); }
});

test('ConfigEditedByHand_TakenOnTheNextMinute', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  const timers = fakeScheduler();
  const check = new SelfCheck({ running: '0.9.0', newestCached: () => null, configStamp: () => fileStamp(paths.configFile), onConfigChange: () => { settings.reload(); }, scheduler: timers.scheduler });
  try {
    check.start();
    writeFileSync(paths.configFile, JSON.stringify(BOTH_PROJECTS));
    const later = new Date(Date.now() + SELF_CHECK_MS);
    utimesSync(paths.configFile, later, later);
    timers.fire(SELF_CHECK_MS);
    assert.deepEqual(settings.view().projects.roots, [FIXTURE_ROOT, LOCAL_ROOT], 'because a hand edit is watched within a minute');
  } finally { check.stop(); cleanup(); }
});
