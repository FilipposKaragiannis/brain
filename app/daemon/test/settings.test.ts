import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config.ts';
import type { DaemonConfig } from '../src/config.ts';
import type { ProjectDefinition } from '../src/project.ts';
import { SettingsStore } from '../src/settings.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';

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
  const settings = new SettingsStore({ config, installed: () => ['ghostty', 'terminal'], applyProjects: (projects) => applied.push(projects) });
  const written = (): unknown => JSON.parse(readFileSync(paths.configFile, 'utf8'));
  return { settings, applied, written, paths, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

const FILE_PROJECT = { 'config.json': { projects: [{ root: FIXTURE_ROOT }] } };

test('View_EachSettingSaysWhereItCameFrom', () => {
  const { settings, paths, cleanup } = store([], FILE_PROJECT);
  try {
    const view = settings.view();
    assert.deepEqual([view.projects.from, view.projects.editable, view.terminal.from, view.port.from, view.port.value], ['file', true, 'default', 'default', 7474], 'because the owner must see which settings the file holds and which are defaults');
    assert.equal(view.configFile, paths.configFile, 'because the screen shows the file to edit by hand');
    assert.deepEqual(view.terminal.installed, ['ghostty', 'terminal'], 'because with no terminal set the first installed one opens');
  } finally { cleanup(); }
});

test('ProjectsFromAFlag_NotEditableWithTheReason', () => {
  const { settings, cleanup } = store(['--project', FIXTURE_ROOT], {});
  try {
    const view = settings.view();
    assert.deepEqual([view.projects.from, view.projects.editable], ['flag', false], 'because a restart would bring the flag back over any edit');
    assert.match(view.projects.note ?? '', /--project/, 'because the screen says why the list is locked');
    const refused = settings.update({ projects: [{ root: LOCAL_ROOT }] });
    assert.equal(refused.ok, false, 'because projects set by a flag cannot change from Settings');
  } finally { cleanup(); }
});

test('PutProjects_WrittenAndAppliedLive', () => {
  const { settings, applied, written, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] });
    assert.ok(result.ok, 'because both roots hold a flow');
    assert.deepEqual(applied.map((projects) => projects.map((project) => project.id)), [['project', 'project-local']], 'because the daemon starts watching the new root without a restart');
    assert.deepEqual(written(), { projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }, 'because the file is what the next start reads');
  } finally { cleanup(); }
});

test('PutRootWithoutFlow_RefusedAndNothingWritten', () => {
  const { settings, applied, paths, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ projects: [{ root: path.join(FIXTURES, 'project-wt-2') }] });
    assert.match(result.ok ? '' : result.error, /no \.flow\/config\.yaml/, 'because a root must hold .flow/config.yaml, and the reason says so');
    assert.deepEqual([applied.length, existsSync(paths.configFile)], [0, true], 'because a refused change leaves the running list and the file as they were');
  } finally { cleanup(); }
});

test('PutRelativeRoot_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ projects: [{ root: 'projects/foo' }] }).ok, false, 'because a relative root would depend on where the daemon was started');
  } finally { cleanup(); }
});

test('PutNoProjects_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ projects: [] }).ok, false, 'because a daemon that watches nothing could not start again');
  } finally { cleanup(); }
});

test('PutTerminal_NameOrCommandKeptOtherSettingsUntouched', () => {
  const { settings, written, cleanup } = store([], FILE_PROJECT);
  try {
    assert.ok(settings.update({ terminal: { command: ['open', '-a', 'Warp', '{path}'] } }).ok, 'because a non-empty command array is a terminal');
    assert.deepEqual(written(), { projects: [{ root: FIXTURE_ROOT }], terminal: { command: ['open', '-a', 'Warp', '{path}'] } }, 'because a PUT changes only what it names');
    assert.deepEqual(settings.terminal(), { command: ['open', '-a', 'Warp', '{path}'] }, 'because the next Open in Terminal uses it without a restart');
  } finally { cleanup(); }
});

test('PutBadTerminal_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    for (const terminal of ['kitty', { command: [] }, { command: ['open', ''] }, ['open']]) {
      assert.equal(settings.update({ terminal }).ok, false, `because ${JSON.stringify(terminal)} is neither a known terminal nor a non-empty command`);
    }
  } finally { cleanup(); }
});

test('PutTerminalNull_BackToTheFirstInstalled', () => {
  const { settings, written, cleanup } = store([], { 'config.json': { projects: [{ root: FIXTURE_ROOT }], terminal: 'iterm' } });
  try {
    settings.update({ terminal: null });
    assert.deepEqual([settings.terminal(), settings.view().terminal.from, written()], [null, 'default', { projects: [{ root: FIXTURE_ROOT }] }], 'because clearing the choice goes back to picking the first installed app');
  } finally { cleanup(); }
});

test('PutPort_SavedButTheDaemonKeepsItsPort', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    const result = settings.update({ port: 7480 });
    assert.ok(result.ok, 'because 7480 is a port');
    assert.deepEqual([result.value.port.value, result.value.port.saved], [7474, 7480], 'because a new port only takes effect after a restart');
    assert.match(result.value.port.note, /restart/, 'because the screen says so');
  } finally { cleanup(); }
});

test('PutUnknownSetting_Refused', () => {
  const { settings, cleanup } = store([], FILE_PROJECT);
  try {
    assert.equal(settings.update({ temrinal: 'iterm' }).ok, false, 'because a typo must not be written and then ignored');
  } finally { cleanup(); }
});

test('LegacyProjectsFile_NotedUntilTheFirstWrite', () => {
  const { settings, written, cleanup } = store([], { 'projects.json': { projects: [{ root: FIXTURE_ROOT }] } });
  try {
    assert.match(settings.view().readFromLegacyFile ?? '', /projects\.json$/, 'because the screen says where the projects came from');
    settings.update({ terminal: 'ghostty' });
    assert.deepEqual([settings.view().readFromLegacyFile, written()], [null, { projects: [{ root: FIXTURE_ROOT }], terminal: 'ghostty' }], 'because the first save moves the projects into config.json');
  } finally { cleanup(); }
});
