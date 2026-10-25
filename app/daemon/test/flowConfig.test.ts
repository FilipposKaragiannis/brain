import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CommandRequest, CommandResult } from '../src/collectors/exec.ts';
import { silentLogger } from '../src/log.ts';
import { applyChange, parseDocument, valueAt } from '../src/plugins/flow/configDocument.ts';
import { contentHash, describe, FlowConfigEditor } from '../src/plugins/flow/configEditor.ts';
import type { FlowConfigDocument, FlowConfigSaved } from '../src/plugins/flow/schema.ts';
import { checkFileValue, checkSchedule, FLOW_CONFIG_SCHEMA } from '../src/plugins/flow/schema.ts';
import { parseYaml } from '../src/yaml.ts';
import { FIXTURES } from './fakeRunner.ts';

/** foosbrawl's .flow/config.yaml as it was on 2026-10-25, copied so the test never reads the project. */
const FOOSBRAWL = readFileSync(path.join(FIXTURES, 'flow-config', 'foosbrawl.yaml'), 'utf8');

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

test('FoosbrawlConfig_ParsesInTheFlatFormat', () => {
  const parsed = parseDocument(FOOSBRAWL);
  assert.ok(parsed.ok, `because the real file is in the format its header names: ${parsed.ok ? '' : parsed.error}`);
});

test('ScalarChange_RewritesOnlyItsValueAndKeepsTheComment', () => {
  const after = edited(FOOSBRAWL, 'notify.desktop', 'scalar', true);
  assert.deepEqual(changedLines(FOOSBRAWL, after), ['  desktop: true   # Slack carries every notification; the macOS one is a truncated Script Editor banner'], 'because only the value moves, the comment after it stays where it was');
  assert.equal(valueAt(parseYaml(after), 'notify.desktop'), 'true', 'because the flow reads the new value back');
});

test('ScheduleChange_RewritesOneLineAndEveryCommentStays', () => {
  const after = edited(FOOSBRAWL, 'jobs.schedule.next', 'scalar', 'every 20m --workers 3 --max-steps 15');
  assert.deepEqual(changedLines(FOOSBRAWL, after), ['    next: every 20m --workers 3 --max-steps 15'], 'because a change touches its own line only');
  assert.equal(after.split('\n').filter((line) => line.trim().startsWith('#')).length, FOOSBRAWL.split('\n').filter((line) => line.trim().startsWith('#')).length, 'because no comment is lost');
});

test('InlineListChange_StaysInline', () => {
  const after = edited(FOOSBRAWL, 'reviews.reviewers', 'list', ['codex', 'copilot']);
  assert.deepEqual(changedLines(FOOSBRAWL, after), ['  reviewers: [codex, copilot]'], 'because a list written inline stays inline');
});

test('BlockListChange_ReplacesTheItemLinesInPlace', () => {
  const pool = ['../foosbrawl-wt-2', '../foosbrawl-wt-3'];
  const after = edited(FOOSBRAWL, 'pool', 'list', pool);
  const lines = after.split('\n');
  const at = lines.indexOf('pool:');
  assert.deepEqual(lines.slice(at, at + 4), ['pool:', '  - ../foosbrawl-wt-2', '  - ../foosbrawl-wt-3', 'pool_max: 9'], 'because the items go where the old ones were and the next key follows');
  assert.deepEqual(valueAt(parseYaml(after), 'pool'), pool, 'because the flow reads the shorter pool');
  assert.equal(lines[at - 1], '# while the pool is below pool_max, and the steward appends it here. 0 never adds.', 'because the comment above the pool stays');
});

test('NewKey_GoesUnderItsSectionsLastLine', () => {
  const after = edited(FOOSBRAWL, 'notify.idle', 'scalar', true);
  const lines = after.split('\n');
  const webhook = lines.findIndex((line) => line.startsWith('  slack_webhook:'));
  assert.equal(lines[webhook + 1], '  idle: true', 'because a new key joins its section after the section\'s last line');
  assert.equal(after.split('\n').length, FOOSBRAWL.split('\n').length + 1, 'because one line is added and nothing else');
});

test('NewKeyUnderAMapHoldingOnlyAComment_GoesAfterTheComment', () => {
  const after = edited(FOOSBRAWL, 'auto_gates.plan-approval', 'scalar', 'S,M');
  const lines = after.split('\n');
  const at = lines.indexOf('auto_gates:');
  assert.deepEqual(lines.slice(at, at + 3), ['auto_gates:', '  # plan-approval: S,M', '  plan-approval: S,M'], 'because the commented example stays above the real line');
  assert.equal(valueAt(parseYaml(after), 'auto_gates.plan-approval'), 'S,M', 'because the flow reads the sizes');
});

test('NewTopLevelKey_GoesAtTheEnd', () => {
  const after = edited(FOOSBRAWL, 'retro.commit', 'scalar', false);
  assert.ok(after.endsWith('retro:\n  commit: false\n'), 'because a key with no section yet is appended at the end, the final newline kept');
});

test('MapChange_RewritesChangedChildrenAndAddsNewOnes', () => {
  const after = edited(FOOSBRAWL, 'gates', 'map', { goldens: 'dotnet run --project src/Foosbrawl.Harness -c Release -- verify-all', lint: 'tools/lint.sh' });
  const lines = after.split('\n');
  const at = lines.indexOf('gates:');
  assert.deepEqual(lines.slice(at, at + 3), ['gates:', '  goldens: dotnet run --project src/Foosbrawl.Harness -c Release -- verify-all', '  lint: tools/lint.sh'], 'because an unchanged gate keeps its line and a new one goes last in the map');
});

test('RemovedKey_TakesItsLineOut', () => {
  const after = edited(FOOSBRAWL, 'reviews.max_chases', 'scalar', null);
  assert.equal(valueAt(parseYaml(after), 'reviews.max_chases'), undefined, 'because null takes the key out of the file');
  assert.equal(after.split('\n').length, FOOSBRAWL.split('\n').length - 1, 'because only its line goes');
});

test('ValueThatNeedsQuotes_Quoted', () => {
  const after = edited(FOOSBRAWL, 'jobs.model', 'scalar', 'opus: fast');
  assert.ok(after.includes('  model: "opus: fast"'), 'because a colon and a space would read as a nested key without quotes');
  assert.equal(valueAt(parseYaml(after), 'jobs.model'), 'opus: fast', 'because the quotes come off when the flow reads it');
});

test('ValueWithSpaceHash_Refused', () => {
  const result = applyChange(FOOSBRAWL, 'jobs.model', 'scalar', 'opus #1');
  assert.equal(result.ok, false, 'because lib/flow.sh cuts a line at " #", so the value would not read back');
});

test('EveryFixtureKeyInTheSchema_ParsesToItsType', () => {
  const values = parseYaml(FOOSBRAWL);
  const present = FLOW_CONFIG_SCHEMA.filter((spec) => valueAt(values, spec.path) !== undefined);
  assert.ok(present.length >= 25, `because the schema covers the keys the real file sets (found ${present.length})`);
  for (const spec of present) {
    const checked = checkFileValue(spec, valueAt(values, spec.path));
    assert.ok(checked.ok, `because ${spec.path} in the real file is a valid ${spec.type}: ${checked.ok ? '' : checked.error}`);
  }
  assert.deepEqual(describe('/p/.flow/config.yaml', FOOSBRAWL).warnings, [], 'because nothing in the real file is out of type');
});

test('FoosbrawlConfig_NoKeyLeftForOther', () => {
  const sections = describe('/p/.flow/config.yaml', FOOSBRAWL).sections;
  assert.equal(sections.find((section) => section.group === 'Other'), undefined, 'because the schema knows every key foosbrawl sets');
});

test('UnknownKey_ShowsInOther', () => {
  const sections = describe('/p/.flow/config.yaml', `${FOOSBRAWL}experiments:\n  fast_lane: on\n`).sections;
  assert.deepEqual(sections.find((section) => section.group === 'Other')?.fields.map((spec) => [spec.path, spec.type]), [['experiments.fast_lane', 'string']], 'because a key the schema does not know is still editable, as text');
});

test('NotTheFlatFormat_RefusedWithTheLine', () => {
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

test('Schedule_TheFormsJobsShTakes', () => {
  for (const good of ['every 30m --workers 2 --max-steps 15', 'every 2h', 'daily 02:00', 'weekly sun 07:00']) assert.ok(checkSchedule(good).ok, `because jobs.sh installs "${good}"`);
  for (const bad of ['every 0m', 'hourly', 'daily 25:00', 'weekly someday 07:00', 'every 10m $(rm -rf ~)']) assert.equal(checkSchedule(bad).ok, false, `because jobs.sh refuses "${bad}"`);
});

/** A project in a temp folder holding the foosbrawl config, with git answering as told. */
function project(gitStatus: CommandResult = { code: 0, stdout: '', stderr: '', timedOut: false }) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'console-flow-config-'));
  mkdirSync(path.join(root, '.flow'));
  const file = path.join(root, '.flow', 'config.yaml');
  writeFileSync(file, FOOSBRAWL);
  const asked: CommandRequest[] = [];
  let refreshed = 0;
  const editor = new FlowConfigEditor({
    projectId: 'foosbrawl', root, log: silentLogger, refresh: async () => { refreshed += 1; },
    runner: async (request) => { asked.push(request); return gitStatus; },
  });
  return { root, file, editor, asked, refreshed: () => refreshed, done: () => rmSync(root, { recursive: true, force: true }) };
}

async function readDocument(editor: FlowConfigEditor): Promise<FlowConfigDocument> {
  const reply = await editor.read();
  assert.equal(reply.status, 200, 'because the file is there');
  return reply.body as FlowConfigDocument;
}

test('ScheduleChangeSaved_FileRewrittenAndTheInstallActionOffered', async () => {
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

test('PoolChangeSaved_SaysItCountsAtTheNextClaim', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const saved = (await fixture.editor.write({ changes: [{ path: 'pool_max', value: 4 }], hash })).body as FlowConfigSaved;
    assert.deepEqual(saved.followUps.map((followUp) => [followUp.action, followUp.note]), [[null, 'The pool reads this at the next claim; nothing to restart.']], 'because nothing has to run, but the owner should know when it counts');
  } finally { fixture.done(); }
});

test('DirtyFile_RefusedUnlessForced', async () => {
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

test('FileChangedSinceTheRead_Refused', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    writeFileSync(fixture.file, FOOSBRAWL.replace('max_chases: 2', 'max_chases: 5'));
    const reply = await fixture.editor.write({ changes: [{ path: 'reviews.chase_after', value: '2h' }], hash, force: true });
    assert.deepEqual([reply.status, (reply.body as { reason: string }).reason], [409, 'stale'], 'because a hand edit made since the read would be lost, force or not');
    assert.ok(readFileSync(fixture.file, 'utf8').includes('max_chases: 5'), 'because the hand edit stays');
  } finally { fixture.done(); }
});

test('ValueOutOfType_RefusedWithTheReason', async () => {
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

test('RawText_SavedWhole', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const text = FOOSBRAWL.replace('  batch: 10', '  batch: 12');
    const reply = await fixture.editor.write({ text, hash });
    assert.deepEqual([reply.status, (reply.body as FlowConfigSaved).saved], [200, ['intake.batch']], 'because the raw save names what it changed');
    assert.equal(readFileSync(fixture.file, 'utf8'), text, 'because raw YAML is written as typed');
  } finally { fixture.done(); }
});

test('RawTextOutOfFormat_Refused', async () => {
  const fixture = project();
  try {
    const { hash } = await readDocument(fixture.editor);
    const reply = await fixture.editor.write({ text: `${FOOSBRAWL}extra: &anchor x\n`, hash });
    assert.ok(reply.status === 400 && /an anchor/.test((reply.body as { error: string }).error), 'because the flow scripts could not read it');
    const typed = await fixture.editor.write({ text: FOOSBRAWL.replace('pool_max: 9', 'pool_max: many'), hash });
    assert.ok(typed.status === 400 && /pool_max must be a whole number/.test((typed.body as { error: string }).error), 'because a raw edit is held to the same types as the form');
  } finally { fixture.done(); }
});

test('Read_CarriesTheHashOfTheText', async () => {
  const fixture = project();
  try {
    const document = await readDocument(fixture.editor);
    assert.deepEqual([document.path, document.hash, document.text === FOOSBRAWL], [fixture.file, contentHash(FOOSBRAWL), true], 'because the PUT sends that hash back to prove it saw this text');
  } finally { fixture.done(); }
});
