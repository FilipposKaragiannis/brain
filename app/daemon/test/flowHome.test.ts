import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandRequest, CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { parseGateList, pluginHasGateJson, readFlowHome } from '../src/collectors/flowHome.ts';
import { FAKE_PLUGIN, FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';

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
});

test('FlowHome_PluginBefore1180_GateListNotCalled', async () => {
  let called = false;
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.17.0', () => { called = true; return { code: 2, stdout: '', stderr: 'usage', timedOut: false }; }));
  assert.equal(called, false, 'because an older plugin has no --json and the call would only fail');
  assert.equal(facts.gates[0]?.questions, null, 'because the daemon then parses the message itself');
});

test('FlowHome_GateListFails_QuestionsNull', async () => {
  const facts = await readFlowHome(FIXTURE_ROOT, runnerWith('1.18.0', () => ({ code: 1, stdout: '', stderr: 'python3: not found', timedOut: false })));
  assert.equal(facts.gates[0]?.questions, null, 'because a failed list must not hide the gate, only its parse');
  assert.equal(facts.gates[0]?.gate, 'ambiguity', 'because the gate record itself is still read from the file');
});

test('PluginHasGateJson_VersionsAndUnknown', () => {
  assert.equal(pluginHasGateJson('1.17.0'), false, 'because --json arrived in 1.18.0');
  assert.equal(pluginHasGateJson('1.18.0'), true, 'because that is the first version with it');
  assert.equal(pluginHasGateJson('1.20.1'), true, 'because later versions keep it');
  assert.equal(pluginHasGateJson('2.0.0'), true, 'because a major bump counts, not just the minor');
  assert.equal(pluginHasGateJson('flow'), true, 'because a dev checkout is tried, and fails cleanly when the flag is unknown');
  assert.equal(pluginHasGateJson(null), true, 'because no version is no reason to skip the call');
});

test('ParseGateList_KeepsOnlyWellFormedQuestions', () => {
  const list = parseGateList(JSON.stringify([
    { item: 'gh#1', questions: [{ number: 1, text: 'A?', recommended: null }, { number: 'x', text: 'bad' }, { number: 2, text: 'B?', recommended: 'yes' }] },
    { item: 7, questions: [] },
    'noise',
  ]));
  assert.deepEqual(list.get('gh#1'), [{ number: 1, text: 'A?', recommended: null }, { number: 2, text: 'B?', recommended: 'yes' }], 'because a malformed question is dropped, not the gate');
  assert.equal(list.size, 1, 'because an entry without a string item names no gate');
  assert.equal(parseGateList('not json').size, 0, 'because unparseable output is no questions, not a crash');
  assert.equal(parseGateList('{}').size, 0, 'because the plugin prints an array');
});
