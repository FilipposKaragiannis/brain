import assert from 'node:assert/strict';
import { test } from 'node:test';
import path from 'node:path';
import type { CommandRequest, CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import type { GateQuestionCache } from '../src/collectors/flowHome.ts';
import { parseFlowConfig, parseGateList, pluginHasGateJson, pluginVersionOf, readFlowHome } from '../src/collectors/flowHome.ts';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { FAKE_PLUGIN, FIXTURES, FIXTURE_ROOT, GATE_LIST_JSON, GATE_RECORD, fakeGateList, fakeRunner } from './fakeRunner.ts';

const failed: CommandResult = { code: 1, stdout: '', stderr: 'python3: command not found\nmore', timedOut: false };
const withQuestions = (questions: unknown[], message = GATE_RECORD.message) => JSON.stringify([{ item: 'gh#7', message, questions }]);

/** The fake runner with the plugin at `version`, and `gate.sh` answered by `gateList`. */
function runnerWith(version: string, gateList: (request: CommandRequest) => CommandResult): CommandRunner {
  return async (request) => {
    if (request.command === 'sh' && request.args[0] === '-c') return { code: 0, stdout: `/fake/plugins/flow/${version}`, stderr: '', timedOut: false };
    if (request.command === 'sh' && request.args[0]?.endsWith('gate.sh')) return gateList(request);
    return fakeRunner(request);
  };
}

test('FlowHome_ConfigPoolAndPlugin', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, fakeRunner);
  assert.equal(facts.config.repo, 'example/fixture', 'because the repo names the tracker');
  assert.equal(facts.config.pool.length, 3, 'because the fixture pool lists three worktrees');
  assert.equal(facts.pluginVersion, '9.9.9', 'because the plugin version is the last path segment plugin.sh resolves');
  assert.equal(facts.pluginRoot, FAKE_PLUGIN, 'because scripts run from the resolved plugin');
});

/** Runs `body` with FLOW_PLUGIN set as given (or unset), then puts the daemon's own value back. */
async function withFlowPlugin<T>(value: string | undefined, body: () => Promise<T>): Promise<T> {
  const kept = process.env['FLOW_PLUGIN'];
  if (value === undefined) delete process.env['FLOW_PLUGIN']; else process.env['FLOW_PLUGIN'] = value;
  try { return await body(); } finally { if (kept === undefined) delete process.env['FLOW_PLUGIN']; else process.env['FLOW_PLUGIN'] = kept; }
}

test('FlowPluginUnset_PluginSourceIsInstalled', async () => {
  const facts = await withFlowPlugin(undefined, () => readFlowHome(FIXTURE_ROOT, fakeRunner));
  assert.equal(facts.pluginSource, 'installed', 'because without FLOW_PLUGIN plugin.sh found the plugin in the cache');
});

test('FlowPluginSet_PluginSourceIsFlowPlugin', async () => {
  const facts = await withFlowPlugin('/work/brain/plugins/flow', () => readFlowHome(FIXTURE_ROOT, fakeRunner));
  assert.equal(facts.pluginSource, 'FLOW_PLUGIN', 'because FLOW_PLUGIN reaches plugin.sh, which takes it over the cache');
});

test('PluginVersion_FromTheManifest_WhenTheFolderIsACheckout', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-plugin-'));
  try {
    const checkout = path.join(dir, 'flow');
    mkdirSync(path.join(checkout, '.claude-plugin'), { recursive: true });
    writeFileSync(path.join(checkout, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'flow', version: '1.19.0' }));
    assert.equal(await pluginVersionOf(checkout), '1.19.0', 'because FLOW_PLUGIN can name a checkout, whose folder is not a version');
    writeFileSync(path.join(checkout, '.claude-plugin', 'plugin.json'), 'not json');
    assert.equal(await pluginVersionOf(checkout), 'flow', 'because a broken manifest falls back to the folder name rather than failing the read');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('FlowHome_GatesRunsClaimsEvents', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, fakeRunner);
  assert.deepEqual(facts.gates.map((gate) => [gate.item, gate.gate]), [['gh#7', 'ambiguity']], 'because one gate record waits');
  assert.equal(facts.runs[0]?.item, 'gh#9', 'because one run record exists');
  assert.ok(facts.runs[0]?.startedAt, 'because the record mtime stands in for the start time');
  assert.deepEqual(facts.claims.map((claim) => claim.item).sort(), ['gh#5', 'gh#7', 'gh#9'], 'because every pool worktree with a claim.json is claimed');
  assert.equal(facts.events[0]?.kind, 'comments', 'because events come newest first');
});

test('FlowHome_GateQuestions_FromPluginList', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, fakeRunner);
  assert.equal(facts.gates[0]?.questions?.[1]?.recommended, 'no, the plugin said so', 'because the plugin\'s parse of the message is the one the card shows');
  assert.equal(facts.gateListError, null, 'because the list worked');
});

test('FlowHome_PluginBefore1180_ListSkipped', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.17.0', (request) => fakeGateList(request)));
  assert.equal(facts.gates[0]?.questions, null, 'because the flag does not exist before 1.18.0, so the list is not asked even when it would answer');
  assert.equal(facts.gateListError, null, 'because a skipped list is not a failure');
});

test('FlowHome_GateListExitsNonZero_GateKeptAndReported', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.18.0', () => failed));
  assert.equal(facts.gates[0]?.gate, 'ambiguity', 'because the gate record itself is still read from the file');
  assert.equal(facts.gates[0]?.questions, null, 'because only the parse is lost');
  assert.equal(facts.gateListError, 'gate.sh list --json exited 1: python3: command not found', 'because the owner must see why the card differs from Slack, with the first line the script said');
});

test('FlowHome_GateListTimedOut_Reported', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.18.0', () => ({ code: null, stdout: '', stderr: '', timedOut: true })));
  assert.match(facts.gateListError ?? '', /timed out after 10s/, 'because a hung steward lookup must not pass as "no questions"');
});

test('FlowHome_GateListPrintsText_ReportedAsNoJson', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('flow', (request) => fakeGateList(request, '2026-10-22T07:43:00Z\tgh#7\tambiguity\t1. Keep the old name?\n')));
  assert.equal(facts.gates[0]?.questions, null, 'because a dev checkout older than 1.18.0 prints its text list with exit 0');
  assert.match(facts.gateListError ?? '', /printed no JSON array/, 'because that is reported, not mistaken for a gate without questions');
});

test('FlowHome_ListMessageDiffers_QuestionsNotPaired', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.18.0', (request) => fakeGateList(request, withQuestions([{ number: 1, text: 'New?', recommended: null }], 'a newer message'))));
  assert.equal(facts.gates[0]?.questions, null, 'because a gate cleared and raised again between the two reads must not show the old text with the new questions');
});

test('FlowHome_QuestionsCached_ListNotAskedAgain', async () => {
  const cache: GateQuestionCache = new Map();
  await readFlowHome(FIXTURE_ROOT, fakeRunner, cache);
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.18.0', () => failed), cache);
  assert.equal(facts.gates[0]?.questions?.length, 2, 'because the parse of an unchanged message is kept, so a waiting gate costs no process per read');
  assert.equal(facts.gateListError, null, 'because the list was not needed, so its failure never happened');
});

test('FlowHome_NoGates_ListNotAsked', async () => {
  const facts = await readFlowHome(path.join(FIXTURES, 'project-local'), runnerWith('1.18.0', () => failed));
  assert.deepEqual(facts.gates, [], 'because the local fixture has no gate records');
  assert.equal(facts.gateListError, null, 'because nothing waits, so the list is not run and cannot fail');
});

test('PluginHasGateJson_OlderVersion_False', () => {
  for (const version of ['1.17.0', '1.17.99', '1.9.0', '0.99.0']) assert.equal(pluginHasGateJson(version), false, `because ${version} is before 1.18.0 by number, not by text`);
});

test('PluginHasGateJson_FromFirstVersion_True', () => {
  for (const version of ['1.18.0', '1.18.1', '1.20.1', '1.100.0', '2.0.0']) assert.equal(pluginHasGateJson(version), true, `because ${version} is 1.18.0 or later by number`);
});

test('PluginHasGateJson_UnknownVersion_Tried', () => {
  for (const version of ['flow', '1.18.0-rc.1', null]) assert.equal(pluginHasGateJson(version), true, `because ${String(version)} is not three numbers, and a try fails with a clear report`);
});

test('ParseGateList_MalformedQuestion_Dropped', () => {
  const list = parseGateList(withQuestions([{ number: 1, text: 'A?', recommended: null }, { number: 'x', text: 'bad' }, { number: 2, text: 'B?', recommended: 'yes' }]));
  assert.deepEqual(list?.get('gh#7')?.questions, [{ number: 1, text: 'A?', recommended: null }, { number: 2, text: 'B?', recommended: 'yes' }], 'because one bad question must not drop the gate\'s other questions');
});

test('ParseGateList_EntryWithoutItemOrMessage_Skipped', () => {
  const list = parseGateList(JSON.stringify([{ item: 7, message: 'm', questions: [] }, { item: 'gh#8', questions: [] }, 'noise']));
  assert.equal(list?.size, 0, 'because an entry names no gate without a string item and the message it parsed');
});

test('ParseGateList_NotAnArray_Null', () => {
  assert.equal(parseGateList('not json'), null, 'because unparseable output is a failed list, not an empty one');
  assert.equal(parseGateList('{}'), null, 'because the plugin prints an array, so anything else is not its output');
});

test('FlowHome_ListJsonFixture_IsTheRealMessage', () => {
  assert.equal((JSON.parse(GATE_LIST_JSON) as { message: string }[])[0]?.message, GATE_RECORD.message, 'because the fake list must echo the record like the plugin does, or the pairing tests prove nothing');
});

test('BehindBase_ReadFromJobsHealthAsThePluginReadsIt', () => {
  const config = parseFlowConfig('jobs:\n  health:\n    behind_base: 30\nhealth:\n  behind_base: 5\n');
  assert.deepEqual([config.behindBase, config.deprecated], [30, []], 'because steward.sh reads jobs.health.behind_base, so that is the one that counts');
});

test('BehindBaseOnlyUnderTheOldKey_StillReadWithAWarning', () => {
  const config = parseFlowConfig('health:\n  behind_base: 5\n');
  assert.equal(config.behindBase, 5, 'because a file written for console 0.5 keeps working for one release');
  assert.match(config.deprecated[0] ?? '', /rename it to jobs\.health\.behind_base/, 'because the owner is told the plugin never read that key');
});
