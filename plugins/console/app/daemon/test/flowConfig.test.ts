import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CommandRequest, CommandResult } from '../src/collectors/exec.ts';
import { silentLogger } from '../src/log.ts';
import { applyChange, parseDocument, valueAt } from '../src/plugins/flow/configDocument.ts';
import { contentHash, describe, FlowConfigEditor, followUpsOf } from '../src/plugins/flow/configEditor.ts';
import { codexDefaults, readHostDefaults } from '../src/plugins/flow/hostDefaults.ts';
import type { FlowConfigDocument, FlowConfigSaved } from '../src/plugins/flow/schema.ts';
import { checkChange, checkFileValue, checkSchedule, fieldAt, FLOW_CONFIG_SCHEMA } from '../src/plugins/flow/schema.ts';
import { parseYaml } from '../src/yaml.ts';
import { FIXTURES } from './fakeRunner.ts';

/** foosbrawl's .flow/config.yaml as it was on 2026-10-25, copied so the test never reads the project. */
const FOOSBRAWL = readFileSync(path.join(FIXTURES, 'flow-config', 'foosbrawl.yaml'), 'utf8');

/**
 * The plugin's own readers, run on the text: `yaml_get` from lib/flow.sh and `pool_add_entry`
 * from steward.sh, cut out of the plugin in this repository and run with sh in a temp folder, so
 * a list the console writes is checked against the parser the flow scripts really use.
 */
const PLUGIN = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'flow');
function shellFunction(file: string, name: string): string {
  const source = readFileSync(path.join(PLUGIN, file), 'utf8');
  const start = source.indexOf(`${name}() {`);
  assert.ok(start >= 0, `because ${file} defines ${name}`);
  return source.slice(start, source.indexOf('\n}\n', start) + 2);
}
function inTemp<T>(text: string, body: (file: string) => T): T {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-yaml-get-'));
  try { const file = path.join(dir, 'config.yaml'); writeFileSync(file, text); return body(file); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function yamlGet(text: string, key: string): string[] {
  return inTemp(text, (file) => execFileSync('sh', ['-c', `${shellFunction('lib/flow.sh', 'yaml_get')}\nyaml_get "$1" "$2"`, 'sh', file, key], { encoding: 'utf8' }).split('\n').filter((line) => line !== ''));
}
function poolAddEntry(text: string, entry: string): string {
  return inTemp(text, (file) => {
    execFileSync('sh', ['-c', `config_file() { printf %s "$1"; }\n${shellFunction('scripts/steward.sh', 'pool_add_entry').replace('f="$(config_file)"', 'f="$CONFIG"')}\npool_add_entry "$1"`, 'sh', entry], { env: { ...process.env, CONFIG: file } });
    return readFileSync(file, 'utf8');
  });
}

/** The lines of `after` that differ from `before`, by position, when both have the same number of lines. */
function changedLines(before: string, after: string): string[] {
  const a = before.split('\n');
  const b = after.split('\n');
  assert.equal(b.length, a.length, 'because a value change keeps the line count');
  return b.filter((line, index) => line !== a[index]);
}

function edited(text: string, pathName: string, shape: 'scalar' | 'list' | 'map', value: Parameters<typeof applyChange>[3]): string {
  const result = applyChange(text, pathName, shape, value);
  assert.ok(result.ok, `because ${pathName} can be changed in the flat format: ${result.ok ? '' : result.error}`);
  return result.ok ? result.text : '';
}

test('FoosbrawlConfig_Parsed_InTheFlatFormat', () => {
  const parsed = parseDocument(FOOSBRAWL);
  assert.ok(parsed.ok, `because the real file is in the format its header names: ${parsed.ok ? '' : parsed.error}`);
});

test('ScalarKey_Changed_OnlyItsValueMovesAndTheCommentStays', () => {
  const after = edited(FOOSBRAWL, 'notify.desktop', 'scalar', true);
  assert.deepEqual(changedLines(FOOSBRAWL, after), ['  desktop: true   # Slack carries every notification; the macOS one is a truncated Script Editor banner'], 'because only the value moves, the comment after it stays where it was');
  assert.equal(valueAt(parseYaml(after), 'notify.desktop'), 'true', 'because the flow reads the new value back');
});

test('ScheduleKey_Changed_OneLineRewrittenAndEveryCommentStays', () => {
  const after = edited(FOOSBRAWL, 'jobs.schedule.next', 'scalar', 'every 20m --workers 3 --max-steps 15');
  assert.deepEqual(changedLines(FOOSBRAWL, after), ['    next: every 20m --workers 3 --max-steps 15'], 'because a change touches its own line only');
  assert.equal(after.split('\n').filter((line) => line.trim().startsWith('#')).length, FOOSBRAWL.split('\n').filter((line) => line.trim().startsWith('#')).length, 'because no comment is lost');
});

test('InlineList_Changed_WrittenAsABlock', () => {
  const after = edited(FOOSBRAWL, 'reviews.reviewers', 'list', ['codex', 'copilot']);
  const lines = after.split('\n');
  const at = lines.indexOf('  reviewers:');
  assert.deepEqual(lines.slice(at, at + 3), ['  reviewers:', '    - codex', '    - copilot'], 'because the steward appends `  - item` under a list key, and lib/flow.sh stops at an inline value, so every list is written as a block');
});

test('List_Cleared_LeftAsABareKey', () => {
  const after = edited(FOOSBRAWL, 'pool', 'list', []);
  const lines = after.split('\n');
  const at = lines.indexOf('pool:');
  assert.equal(lines[at + 1], 'pool_max: 9', 'because flow:init writes an empty pool as a bare pool: line, never pool: []');
  assert.deepEqual(yamlGet(after, 'pool'), [], 'because the plugin reads no entry');
});

test('BlockList_Changed_ItemLinesReplacedInPlace', () => {
  const pool = ['../foosbrawl-wt-2', '../foosbrawl-wt-3'];
  const after = edited(FOOSBRAWL, 'pool', 'list', pool);
  const lines = after.split('\n');
  const at = lines.indexOf('pool:');
  assert.deepEqual(lines.slice(at, at + 4), ['pool:', '  - ../foosbrawl-wt-2', '  - ../foosbrawl-wt-3', 'pool_max: 9'], 'because the items go where the old ones were and the next key follows');
  assert.deepEqual(valueAt(parseYaml(after), 'pool'), pool, 'because the flow reads the shorter pool');
  assert.equal(lines[at - 1], '# while the pool is below pool_max, and the steward appends it here. 0 never adds.', 'because the comment above the pool stays');
});

test('NewKey_Added_GoesUnderItsSectionsLastLine', () => {
  const after = edited(FOOSBRAWL, 'notify.idle', 'scalar', true);
  const lines = after.split('\n');
  const webhook = lines.findIndex((line) => line.startsWith('  slack_webhook:'));
  assert.equal(lines[webhook + 1], '  idle: true', 'because a new key joins its section after the section\'s last line');
  assert.equal(after.split('\n').length, FOOSBRAWL.split('\n').length + 1, 'because one line is added and nothing else');
});

test('NewKeyUnderAMapHoldingOnlyAComment_Added_GoesAfterTheComment', () => {
  const after = edited(FOOSBRAWL, 'auto_gates.plan-approval', 'scalar', 'S,M');
  const lines = after.split('\n');
  const at = lines.indexOf('auto_gates:');
  assert.deepEqual(lines.slice(at, at + 3), ['auto_gates:', '  # plan-approval: S,M', '  plan-approval: S,M'], 'because the commented example stays above the real line');
  assert.equal(valueAt(parseYaml(after), 'auto_gates.plan-approval'), 'S,M', 'because the flow reads the sizes');
});

test('NewTopLevelKey_Added_GoesAtTheEnd', () => {
  const after = edited(FOOSBRAWL, 'retro.commit', 'scalar', false);
  assert.ok(after.endsWith('retro:\n  commit: false\n'), 'because a key with no section yet is appended at the end, the final newline kept');
});

test('MapKey_Changed_ChangedChildrenRewrittenAndNewOnesAdded', () => {
  const after = edited(FOOSBRAWL, 'gates', 'map', { goldens: 'dotnet run --project src/Foosbrawl.Harness -c Release -- verify-all', lint: 'tools/lint.sh' });
  const lines = after.split('\n');
  const at = lines.indexOf('gates:');
  assert.deepEqual(lines.slice(at, at + 3), ['gates:', '  goldens: dotnet run --project src/Foosbrawl.Harness -c Release -- verify-all', '  lint: tools/lint.sh'], 'because an unchanged gate keeps its line and a new one goes last in the map');
});

test('Key_SetToNull_ItsLineTakenOut', () => {
  const after = edited(FOOSBRAWL, 'reviews.max_chases', 'scalar', null);
  assert.equal(valueAt(parseYaml(after), 'reviews.max_chases'), undefined, 'because null takes the key out of the file');
  assert.equal(after.split('\n').length, FOOSBRAWL.split('\n').length - 1, 'because only its line goes');
});

test('ValueWithColonSpace_Written_Quoted', () => {
  const after = edited(FOOSBRAWL, 'jobs.model', 'scalar', 'opus: fast');
  assert.ok(after.includes('  model: "opus: fast"'), 'because a colon and a space would read as a nested key without quotes');
  assert.equal(valueAt(parseYaml(after), 'jobs.model'), 'opus: fast', 'because the quotes come off when the flow reads it');
});

test('ValueWithSpaceHash_Written_Refused', () => {
  const result = applyChange(FOOSBRAWL, 'jobs.model', 'scalar', 'opus #1');
  assert.equal(result.ok, false, 'because lib/flow.sh cuts a line at " #", so the value would not read back');
});

test('ListWrittenByTheConsole_ReadByThePluginsYamlGet_SameItems', () => {
  const pool = ['../foosbrawl-wt-2', '../foosbrawl-wt-3'];
  const after = edited(FOOSBRAWL.replace(/^pool:\n(  - .*\n)+/m, 'pool: [../foosbrawl-wt-9]\n'), 'pool', 'list', pool);
  assert.deepEqual(yamlGet(after, 'pool'), pool, 'because the flow scripts read the pool with lib/flow.sh, not with the console');
  assert.deepEqual(valueAt(parseYaml(after), 'pool'), pool, 'because the console reads the same list');
});

test('StewardAppendsAfterAConsoleWrite_BothParsers_ReadTheWholePool', () => {
  for (const start of [['../foosbrawl-wt-2'], []]) {
    const written = edited(FOOSBRAWL, 'pool', 'list', start);
    const appended = poolAddEntry(written, '../foosbrawl-wt-11');
    const want = [...start, '../foosbrawl-wt-11'];
    assert.deepEqual(yamlGet(appended, 'pool'), want, `because grow_pool's new worktree must join the pool the plugin reads (pool of ${start.length})`);
    assert.ok(parseDocument(appended).ok, 'because the console must still parse the file the steward wrote');
    assert.deepEqual(valueAt(parseYaml(appended), 'pool'), want, 'because the console reads the same pool');
  }
});

test('ScalarStartingWithABracket_Written_Refused', () => {
  const result = applyChange(FOOSBRAWL, 'jobs.model', 'scalar', '[wip]');
  assert.ok(!result.ok && /starts with \[ or \{/.test(result.error), 'because lib/flow.sh strips the quotes and then reads [wip] as the list wip');
});

test('ValueWithATab_ParsedOrWritten_Refused', () => {
  const parsed = parseDocument('jobs:\n  model: opus\t# fast\n');
  assert.ok(!parsed.ok && /a tab in the value of model/.test(parsed.error), 'because lib/flow.sh ends the value at a tab before #, and the console would read "opus\t# fast"');
  assert.equal(applyChange(FOOSBRAWL, 'jobs.model', 'scalar', 'opus\tfast').ok, false, 'because a tab never reads back the same in both parsers');
});

test('FixtureKeysInTheSchema_Parsed_EachFitsItsType', () => {
  const values = parseYaml(FOOSBRAWL);
  const present = FLOW_CONFIG_SCHEMA.filter((spec) => valueAt(values, spec.path) !== undefined);
  assert.ok(present.length >= 25, `because the schema covers the keys the real file sets (found ${present.length})`);
  for (const spec of present) {
    const checked = checkFileValue(spec, valueAt(values, spec.path));
    assert.ok(checked.ok, `because ${spec.path} in the real file is a valid ${spec.type}: ${checked.ok ? '' : checked.error}`);
  }
  assert.deepEqual(describe('/p/.flow/config.yaml', FOOSBRAWL).warnings, [], 'because nothing in the real file is out of type');
});

test('FoosbrawlConfig_Described_NoKeyLeftForOther', () => {
  const sections = describe('/p/.flow/config.yaml', FOOSBRAWL).sections;
  assert.equal(sections.find((section) => section.group === 'Other'), undefined, 'because the schema knows every key foosbrawl sets');
});

test('UnknownKey_Described_ShowsInOther', () => {
  const sections = describe('/p/.flow/config.yaml', `${FOOSBRAWL}experiments:\n  fast_lane: on\n`).sections;
  assert.deepEqual(sections.find((section) => section.group === 'Other')?.fields.map((spec) => [spec.path, spec.type]), [['experiments.fast_lane', 'string']], 'because a key the schema does not know is still editable, as text');
});

test('TextOutsideTheFlatFormat_Parsed_RefusedWithTheLine', () => {
  const cases: [string, RegExp][] = [
    ['base: main\nalias: &a x\n', /line 2: an anchor/],
    ['jobs:\n\tmodel: x\n', /line 2: a tab/],
    ['notes: |\n  more\n', /line 1: a multi-line string/],
    ['pool:\n  - name: a\n', /line 2: a list of maps/],
    ['base: main\nbase: dev\n', /line 2: base is set twice/],
    ['jobs:\n   model: x\n', /line 2: indented by 3/],
  ];
  for (const [text, reason] of cases) {
    const parsed = parseDocument(text);
    assert.ok(!parsed.ok && reason.test(parsed.error), `because ${JSON.stringify(text)} is outside the format and the refusal names where (${parsed.ok ? 'parsed' : parsed.error})`);
  }
});

test('Schedule_Checked_TakesTheFormsJobsShTakes', () => {
  for (const good of ['every 30m --workers 2 --max-steps 15', 'every 2h', 'daily 02:00', 'weekly sun 07:00']) assert.ok(checkSchedule(good).ok, `because jobs.sh installs "${good}"`);
  for (const bad of ['every 0m', 'hourly', 'daily 25:00', 'weekly someday 07:00', 'every 10m $(rm -rf ~)']) assert.equal(checkSchedule(bad).ok, false, `because jobs.sh refuses "${bad}"`);
});

/** A home folder whose ~/.codex/config.toml sets gpt-6-sol and high. */
const HOME = path.join(FIXTURES, 'home');

/** A project in a temp folder holding the foosbrawl config, with git answering as told. */
function project(gitStatus: CommandResult = { code: 0, stdout: '', stderr: '', timedOut: false }) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'console-flow-config-'));
  mkdirSync(path.join(root, '.flow'));
  const file = path.join(root, '.flow', 'config.yaml');
  writeFileSync(file, FOOSBRAWL);
  const asked: CommandRequest[] = [];
  let refreshed = 0;
  const editor = new FlowConfigEditor({
    projectId: 'foosbrawl', root, log: silentLogger, refresh: async () => { refreshed += 1; }, home: HOME,
    runner: async (request) => { asked.push(request); return gitStatus; },
  });
  return { root, file, editor, asked, refreshed: () => refreshed, done: () => rmSync(root, { recursive: true, force: true }) };
}

async function readDocument(editor: FlowConfigEditor): Promise<FlowConfigDocument> {
  const reply = await editor.read();
  assert.equal(reply.status, 200, 'because the file is there');
  return reply.body as FlowConfigDocument;
}

test('ScheduleChange_Saved_FileRewrittenAndTheInstallActionOffered', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ changes: [{ path: 'jobs.schedule.next', value: 'every 20m --workers 2' }], hash });
    assert.equal(reply.status, 200, `because the schedule is valid and the file clean: ${JSON.stringify(reply.body)}`);
    const saved = reply.body as FlowConfigSaved;
    assert.deepEqual(saved.saved, ['jobs.schedule.next'], 'because that is the one key whose value changed');
    assert.deepEqual(saved.followUps.map((followUp) => [followUp.action?.kind, followUp.paths]), [['jobs.install', ['jobs.schedule.next']]], 'because launchd keeps the old schedule until jobs.sh install writes the new one');
    assert.ok(readFileSync(fixture.file, 'utf8').includes('    next: every 20m --workers 2\n'), 'because the file on disk holds the new schedule');
    assert.equal(fixture.refreshed(), 1, 'because the snapshot must show the saved file');
    assert.deepEqual(fixture.asked.map((request) => request.args), [['status', '--porcelain', '--', '.flow/config.yaml']], 'because git is asked about this one file');
  } finally { fixture.done(); }
});

test('PoolChange_Saved_SaysItCountsAtTheNextClaim', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const saved = (await fixture.editor.write({ changes: [{ path: 'pool_max', value: 4 }], hash })).body as FlowConfigSaved;
    assert.deepEqual(saved.followUps.map((followUp) => [followUp.action, followUp.note]), [[null, 'The pool reads this at the next claim; nothing to restart.']], 'because nothing has to run, but the owner should know when it counts');
  } finally { fixture.done(); }
});

test('ModifiedTrackedFile_Saved_RefusedUnlessForced', async () => {
  const fixture = project({ code: 0, stdout: ' M .flow/config.yaml\n', stderr: '', timedOut: false });
  try {
    const { hash } = await readDocument(fixture.editor);
    const change = { changes: [{ path: 'reviews.max_chases', value: 3 }], hash };
    const refused = await fixture.editor.write(change);
    assert.deepEqual([refused.status, (refused.body as { reason: string }).reason], [409, 'dirty'], 'because the console must not mix its edit into uncommitted work in a tracked file');
    assert.equal(readFileSync(fixture.file, 'utf8'), FOOSBRAWL, 'because a refused write leaves the file alone');
    const forced = await fixture.editor.write({ ...change, force: true });
    assert.equal(forced.status, 200, 'because the owner may say save anyway');
  } finally { fixture.done(); }
});

test('UntrackedFile_Saved_WrittenWithANote', async () => {
  const fixture = project({ code: 0, stdout: '?? .flow/config.yaml\n', stderr: '', timedOut: false });
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ changes: [{ path: 'reviews.max_chases', value: 3 }], hash });
    assert.deepEqual([reply.status, (reply.body as FlowConfigSaved).notes], [200, ['.flow/config.yaml is not tracked by git: add and commit it to keep the change']], 'because an untracked file holds no committed work to mix with, but git will not keep the change either');
  } finally { fixture.done(); }
});

test('ProjectNotAGitCheckout_Saved_WrittenWithANote', async () => {
  const fixture = project({ code: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n', timedOut: false });
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ changes: [{ path: 'reviews.max_chases', value: 3 }], hash });
    assert.equal(reply.status, 200, 'because only a modified tracked file is refused');
    assert.match((reply.body as FlowConfigSaved).notes[0] ?? '', /git could not read the project \(fatal: not a git repository/, 'because the owner hears why nothing checked for uncommitted work');
  } finally { fixture.done(); }
});

test('FileChangedWhileGitWasAsked_Saved_RefusedAsStale', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const stewardEdit = FOOSBRAWL.replace('  - ../foosbrawl-wt-10\n', '  - ../foosbrawl-wt-10\n  - ../foosbrawl-wt-11\n');
    const racing = new FlowConfigEditor({
      projectId: 'foosbrawl', root: fixture.root, log: silentLogger, refresh: async () => {},
      runner: async () => { writeFileSync(fixture.file, stewardEdit); return { code: 0, stdout: '', stderr: '', timedOut: false }; },
    });
    const reply = await racing.write({ changes: [{ path: 'reviews.max_chases', value: 3 }], hash });
    assert.deepEqual([reply.status, (reply.body as { reason: string }).reason], [409, 'stale'], 'because the steward appended to the pool during the git check, and a write from the old text would drop it');
    assert.equal(readFileSync(fixture.file, 'utf8'), stewardEdit, 'because the steward\'s entry stays');
  } finally { fixture.done(); }
});

test('Save_Written_KeepsTheFileModeAndLeavesNoTempFile', async () => {
  const fixture = project();
  try {
    chmodSync(fixture.file, 0o640);
    const { hash } = await readDocument(fixture.editor);
    await fixture.editor.write({ changes: [{ path: 'reviews.max_chases', value: 3 }], hash });
    assert.equal(statSync(fixture.file).mode & 0o777, 0o640, 'because the file is renamed over from a temp copy, which takes the old mode');
    assert.deepEqual(readdirSync(path.dirname(fixture.file)), ['config.yaml'], 'because the temp file is renamed, not left beside it');
  } finally { fixture.done(); }
});

test('ScheduleRemoved_Saved_UninstallOfferedForThatJob', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const saved = (await fixture.editor.write({ changes: [{ path: 'jobs.schedule.retro', value: null }], hash })).body as FlowConfigSaved;
    assert.deepEqual(saved.followUps.map((followUp) => [followUp.action?.kind, followUp.action?.args]), [['job.uninstall', { job: 'retro' }]], 'because jobs.sh install never touches a job without a schedule, so retro\'s launchd agent would keep running');
  } finally { fixture.done(); }
});

test('EverySchedule_Removed_NoInstallOffered', () => {
  const after = parseYaml('jobs:\n  schedule:\n    next: ""\n');
  const kinds = followUpsOf(['jobs.schedule.next', 'jobs.schedule.health'], after).map((followUp) => followUp.action?.args['job']);
  assert.deepEqual(kinds, ['next', 'health'], 'because jobs.sh install exits 2 when no job has a schedule; each job is unloaded instead');
});

test('FileChangedSinceTheRead_Saved_RefusedAsStale', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    writeFileSync(fixture.file, FOOSBRAWL.replace('max_chases: 2', 'max_chases: 5'));
    const reply = await fixture.editor.write({ changes: [{ path: 'reviews.chase_after', value: '2h' }], hash, force: true });
    assert.deepEqual([reply.status, (reply.body as { reason: string }).reason], [409, 'stale'], 'because a hand edit made since the read would be lost, force or not');
    assert.ok(readFileSync(fixture.file, 'utf8').includes('max_chases: 5'), 'because the hand edit stays');
  } finally { fixture.done(); }
});

test('ValueOutOfType_Saved_RefusedWithTheReason', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const cases: [unknown, RegExp][] = [
      [{ path: 'jobs.host', value: 'gemini' }, /one of claude, codex/],
      [{ path: 'pool_max', value: -1 }, /at least 0/],
      [{ path: 'reviews.chase_after', value: 'soon' }, /like 10m or 24h/],
      [{ path: 'jobs.schedule.health', value: 'every now and then' }, /cannot read the schedule/],
      [{ path: 'notify.idle', value: 'yes' }, /true or false/],
    ];
    for (const [change, reason] of cases) {
      const reply = await fixture.editor.write({ changes: [change], hash });
      assert.ok(reply.status === 400 && reason.test((reply.body as { error: string }).error), `because ${JSON.stringify(change)} does not fit its key (${JSON.stringify(reply.body)})`);
    }
    assert.equal(readFileSync(fixture.file, 'utf8'), FOOSBRAWL, 'because nothing refused reaches the file');
  } finally { fixture.done(); }
});

test('RawText_Saved_WrittenWhole', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const text = FOOSBRAWL.replace('  batch: 10', '  batch: 12');
    const reply = await fixture.editor.write({ text, hash });
    assert.deepEqual([reply.status, (reply.body as FlowConfigSaved).saved], [200, ['intake.batch']], 'because the raw save names what it changed');
    assert.equal(readFileSync(fixture.file, 'utf8'), text, 'because raw YAML is written as typed');
  } finally { fixture.done(); }
});

test('RawTextOutOfFormat_Saved_Refused', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ text: `${FOOSBRAWL}extra: &anchor x\n`, hash });
    assert.ok(reply.status === 400 && /an anchor/.test((reply.body as { error: string }).error), 'because the flow scripts could not read it');
    const typed = await fixture.editor.write({ text: FOOSBRAWL.replace('pool_max: 9', 'pool_max: many'), hash });
    assert.ok(typed.status === 400 && /pool_max must be a whole number/.test((typed.body as { error: string }).error), 'because a raw edit is held to the same types as the form');
  } finally { fixture.done(); }
});

test('Document_Read_CarriesTheHashOfTheText', async () => {
  const fixture = project();
  try {
    const document = await readDocument(fixture.editor);
    assert.deepEqual([document.path, document.hash, document.text === FOOSBRAWL], [fixture.file, contentHash(FOOSBRAWL), true], 'because the PUT sends that hash back to prove it saw this text');
  } finally { fixture.done(); }
});

test('JobsHostKeys_InTheSchema_EnumsInTheJobsGroupWithNoFollowUp', () => {
  const expected: [string, string[]][] = [
    ['jobs.claude.model', ['opus', 'sonnet', 'haiku', 'fable']],
    ['jobs.claude.effort', ['low', 'medium', 'high', 'xhigh', 'max']],
    ['jobs.codex.model', ['gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna']],
    ['jobs.codex.effort', ['low', 'medium', 'high', 'xhigh']],
  ];
  for (const [key, values] of expected) {
    const spec = fieldAt(key);
    assert.deepEqual([spec?.type, spec?.group, spec?.values, spec?.followUp], ['enum', 'Jobs', values, null], `because ${key} is picked from the host's own list and the next job run reads it from the file`);
    assert.ok(checkChange(spec!, values[0]!).ok && checkChange(spec!, '').ok && checkChange(spec!, null).ok, `because ${key} takes its values, and empty or unset for the host's default`);
    assert.match(spec!.help, /empty takes the (Claude|Codex) CLI's default/, `because the help of ${key} says what empty means`);
  }
  assert.equal(fieldAt('jobs.host')?.help, 'Which CLI runs the scheduled jobs. The workers inside a run keep their own models.', 'because the host picks the jobs\' CLI, not the workers\' models');
  assert.deepEqual(['jobs.model', 'jobs.effort'].map((key) => fieldAt(key)?.deprecated), Array(2).fill('Deprecated: flow 1.20.0 reads jobs.<host>.model and jobs.<host>.effort. Set those and clear these.'), 'because flow 1.20.0 stopped reading the old keys');
});

test('JobsHostEffort_OutOfItsEnum_RefusedOnPutWithTheRule', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ changes: [{ path: 'jobs.codex.effort', value: 'max' }], hash });
    assert.deepEqual([reply.status, (reply.body as { error: string }).error], [400, 'jobs.codex.effort must be one of low, medium, high, xhigh, not "max"'], 'because codex has no max effort, and the reason names the allowed ones');
    assert.equal(readFileSync(fixture.file, 'utf8'), FOOSBRAWL, 'because nothing refused reaches the file');
  } finally { fixture.done(); }
});

test('CodexModel_Saved_NestedUnderJobsAsABlockWithTheCommentsKept', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ changes: [{ path: 'jobs.codex.model', value: 'gpt-6-astra' }, { path: 'jobs.codex.effort', value: 'xhigh' }, { path: 'jobs.host', value: 'codex' }], hash });
    assert.equal(reply.status, 200, `because both are in codex's lists: ${JSON.stringify(reply.body)}`);
    const text = readFileSync(fixture.file, 'utf8');
    const lines = text.split('\n');
    const at = lines.indexOf('  codex:');
    assert.deepEqual(lines.slice(at, at + 3), ['  codex:', '    model: gpt-6-astra', '    effort: xhigh'], 'because a new nested key goes under jobs: as a block, two spaces a level');
    assert.ok(at > lines.indexOf('jobs:') && at < lines.indexOf('intake:'), 'because the codex block belongs to the jobs section');
    assert.deepEqual(['jobs.codex.model', 'jobs.codex.effort', 'jobs.host'].map((key) => yamlGet(text, key)), [['gpt-6-astra'], ['xhigh'], ['codex']], 'because lib/flow.sh reads the nested keys back the way the console wrote them');
    assert.equal(text.split('\n').filter((line) => line.trim().startsWith('#')).length, FOOSBRAWL.split('\n').filter((line) => line.trim().startsWith('#')).length, 'because no comment is lost');
    assert.ok(text.includes('  permission_mode: auto   # unattended sessions'), 'because a trailing comment on another key stays');
    assert.deepEqual((reply.body as FlowConfigSaved).saved.toSorted(), ['jobs.codex.effort', 'jobs.codex.model', 'jobs.host'], 'because those are the keys whose value changed');
  } finally { fixture.done(); }
});

test('CodexConfig_Read_TopLevelModelAndEffortOnly', async () => {
  assert.deepEqual(await readHostDefaults(HOME), { codex: { model: 'gpt-6-sol', effort: 'high' } }, 'because the top-level lines are codex\'s defaults, and a profile\'s lines below a table are not');
  assert.deepEqual(codexDefaults('approval_policy = "never"\n[profiles.x]\nmodel = "gpt-6-luna"\n'), { model: null, effort: null }, 'because a file that sets neither at the top names no default');
  assert.deepEqual(codexDefaults('model = gpt-6-sol\nmodel_reasoning_effort = "low"\n'), { model: null, effort: 'low' }, 'because only simple key = "value" lines are read, anything else is skipped rather than guessed at');
});

test('CodexConfig_Missing_NoCodexDefaults', async () => {
  const empty = mkdtempSync(path.join(os.tmpdir(), 'console-home-'));
  try {
    assert.deepEqual(await readHostDefaults(empty), { codex: null }, 'because without ~/.codex/config.toml the console cannot name a default');
  } finally { rmSync(empty, { recursive: true, force: true }); }
});

test('Document_ReadAndSaved_CarriesTheHostDefaults', async () => {
  const fixture = project();
  try {
    const document = await readDocument(fixture.editor);
    assert.deepEqual(document.hostDefaults, { codex: { model: 'gpt-6-sol', effort: 'high' } }, 'because the help of the codex model and effort names this machine\'s default');
    const saved = (await fixture.editor.write({ changes: [{ path: 'jobs.codex.model', value: 'gpt-6-luna' }], hash: document.hash })).body as FlowConfigSaved;
    assert.deepEqual(saved.hostDefaults, document.hostDefaults, 'because a save replaces the document the form shows, defaults included');
  } finally { fixture.done(); }
});
