import assert from 'node:assert/strict';
import { test } from 'node:test';
import { scriptEnvironment } from '../src/collectors/exec.ts';

test('ScriptEnvironment_PassesFlowPluginAndDropsTheRest', () => {
  const before = { plugin: process.env.FLOW_PLUGIN, secret: process.env.CONSOLE_TEST_SECRET };
  process.env.FLOW_PLUGIN = '/checkouts/brain/plugins/flow';
  process.env.CONSOLE_TEST_SECRET = 'leak';
  try {
    const env = scriptEnvironment();
    assert.equal(env.FLOW_PLUGIN, '/checkouts/brain/plugins/flow', 'because the owner points the console at an uninstalled plugin this way');
    assert.equal('CONSOLE_TEST_SECRET' in env, false, 'because flow scripts only get the names the daemon lists');
    assert.equal(env.LANG, 'C', 'because script output is parsed, so it must not be localised');
  } finally {
    if (before.plugin === undefined) delete process.env.FLOW_PLUGIN; else process.env.FLOW_PLUGIN = before.plugin;
    if (before.secret === undefined) delete process.env.CONSOLE_TEST_SECRET; else process.env.CONSOLE_TEST_SECRET = before.secret;
  }
});
