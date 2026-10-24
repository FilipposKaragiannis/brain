import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { FAKE_PLUGIN, FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';

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
