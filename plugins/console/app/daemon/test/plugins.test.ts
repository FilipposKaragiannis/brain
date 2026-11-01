import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { compareVersions, flowMarketplace, installedPlugins, parseClaudeInstalled, parseCodexEnabled, pluginReader } from '../src/collectors/plugins.ts';
import type { ClaudeInstall } from '../src/collectors/plugins.ts';

const ROOT = '/work/projects/app';
const install = (key: string, scope: string, version: string, projectPath?: string) => ({ scope, version, installPath: `/cache/${key}/${version}`, ...(projectPath === undefined ? {} : { projectPath }) });
const installedJson = (plugins: Record<string, unknown[]>): string => JSON.stringify({ version: 2, plugins });

function claudeOf(plugins: Record<string, unknown[]>): ClaudeInstall[] {
  return parseClaudeInstalled(installedJson(plugins));
}

const clues = (claude: ClaudeInstall[], extra: Partial<Parameters<typeof installedPlugins>[0]> = {}) =>
  installedPlugins({ root: ROOT, marketplace: 'brain-plugins', claude, codex: [], codexVersions: {}, ...extra });

test('ClaudeInstall_ProjectEntryAndUserEntry_ProjectEntryWins', () => {
  const claude = claudeOf({ 'flow@brain-plugins': [install('flow', 'user', '1.27.1'), install('flow', 'project', '1.11.0', ROOT)] });
  assert.deepEqual(clues(claude), [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.11.0', codex: null }], 'because the project\'s own install is what Claude Code loads there, over the user one');
});

test('ClaudeInstall_LocalScopeAtTheRoot_Wins', () => {
  const claude = claudeOf({ 'flow@brain-plugins': [install('flow', 'user', '1.27.1'), install('flow', 'local', '1.20.0', ROOT)] });
  assert.equal(clues(claude)[0]?.claude, '1.20.0', 'because a local-scope install at the root is the project\'s own too');
});

test('ClaudeInstall_AnotherProjectsEntry_Ignored', () => {
  const claude = claudeOf({
    'flow@brain-plugins': [install('flow', 'project', '1.10.0', '/work/projects/other'), install('flow', 'user', '1.27.1')],
    'craft@brain-plugins': [install('craft', 'project', '1.0.0', '/work/projects/other')],
  });
  assert.deepEqual(clues(claude), [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.27.1', codex: null }], 'because another project\'s install says nothing of this one: flow falls to the user entry and craft is not installed here');
});

test('CodexEnabled_SeveralVersionFolders_NewestNumerically', () => {
  const codex = parseCodexEnabled('[plugins."flow@brain-plugins"]\nenabled = true\n');
  const plugins = clues([], { codex, codexVersions: { flow: ['1.9.2', '1.10.0', '1.2.0'] } });
  assert.deepEqual(plugins, [{ name: 'flow', marketplace: 'brain-plugins', claude: null, codex: '1.10.0' }], 'because versions compare on their numbers, as .flow/plugin.sh sorts them, so 1.10.0 beats 1.9.2');
});

test('CodexNotEnabled_VersionFoldersPresent_Null', () => {
  const codex = parseCodexEnabled('[plugins."flow@brain-plugins"]\nenabled = false\n\n[plugins."craft@brain-plugins"]\n# no enabled line\n');
  const claude = claudeOf({ 'flow@brain-plugins': [install('flow', 'user', '1.27.1')] });
  const plugins = clues(claude, { codex, codexVersions: { flow: ['1.27.1'], craft: ['1.0.0'] } });
  assert.deepEqual(plugins, [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.27.1', codex: null }], 'because a plugin in the Codex cache that the config does not enable is not loaded, and craft has no host');
});

test('CodexConfig_OtherTablesAndKeys_OnlyPluginTablesEnable', () => {
  const source = [
    'model = "gpt-5"', 'enabled = true', '', '[plugins."workstream@brain-plugins"]', 'enabled = true # on', '',
    '[projects."/work/brain"]', 'enabled = true', '', "[plugins.'meta@brain-plugins']", 'enabled=true',
  ].join('\n');
  assert.deepEqual(parseCodexEnabled(source), [{ name: 'workstream', marketplace: 'brain-plugins' }, { name: 'meta', marketplace: 'brain-plugins' }], 'because only an enabled line inside a plugins table enables a plugin');
});

test('Plugins_OtherMarketplace_Excluded', () => {
  const claude = claudeOf({ 'flow@brain-plugins': [install('flow', 'user', '1.27.1')], 'claude-code-setup@claude-plugins-official': [install('claude-code-setup', 'user', '1.0.0')] });
  const codex = parseCodexEnabled('[plugins."github@openai-curated"]\nenabled = true\n');
  const plugins = clues(claude, { codex, codexVersions: { github: ['1.0.0'] } });
  assert.deepEqual(plugins.map((plugin) => plugin.name), ['flow'], 'because the card lists flow\'s marketplace only');
});

test('Plugins_BothHosts_SortedByName', () => {
  const claude = claudeOf({ 'meta@brain-plugins': [install('meta', 'user', '1.1.2')], 'flow@brain-plugins': [install('flow', 'user', '1.27.1')] });
  const codex = parseCodexEnabled('[plugins."workstream@brain-plugins"]\nenabled = true\n[plugins."flow@brain-plugins"]\nenabled = true\n');
  const plugins = clues(claude, { codex, codexVersions: { workstream: ['1.2.3'], flow: ['1.27.0'] } });
  assert.deepEqual(plugins.map((plugin) => [plugin.name, plugin.claude, plugin.codex]), [['flow', '1.27.1', '1.27.0'], ['meta', '1.1.2', null], ['workstream', null, '1.2.3']], 'because a plugin shows when either host has it, by name');
});

test('ClaudeInstalled_NotJsonOrWrongShape_Empty', () => {
  assert.deepEqual([parseClaudeInstalled('{oops'), parseClaudeInstalled('[]'), parseClaudeInstalled(null)], [[], [], []], 'because a broken file means no installs, not a crash');
});

test('CompareVersions_DottedNumbers_Numeric', () => {
  assert.ok(compareVersions('1.10.0', '1.9.2') > 0 && compareVersions('2.0', '10.0') < 0, 'because each part compares as a number, not as text');
});

test('FlowMarketplace_ClaudeInstallFirst_ThenCodexCache_ThenPluginFolder_ThenDefault', () => {
  const base = { root: ROOT, claude: [], codex: [], codexFlowMarketplaces: [], pluginRoot: null };
  assert.deepEqual([
    flowMarketplace({ ...base, claude: claudeOf({ 'flow@mine': [install('flow', 'user', '1.0.0')] }), codexFlowMarketplaces: ['theirs'] }),
    flowMarketplace({ ...base, codexFlowMarketplaces: ['theirs'] }),
    flowMarketplace({ ...base, pluginRoot: '/home/u/.claude/plugins/cache/folder-market/flow/1.27.1' }),
    flowMarketplace(base),
  ], ['mine', 'theirs', 'folder-market', 'brain-plugins'], 'because flow\'s own install names its marketplace, then the Codex cache, then the folder the project\'s flow sits in');
});

test('PluginReader_MissingFiles_Empty', async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), 'plugins-empty-'));
  try {
    assert.deepEqual(await pluginReader(home)(ROOT, null), [], 'because a home with neither host installed has no plugins, and the read does not fail');
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test('PluginReader_BothHostsFiles_ReadFromTheHome', async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), 'plugins-home-'));
  try {
    mkdirSync(path.join(home, '.claude', 'plugins'), { recursive: true });
    writeFileSync(path.join(home, '.claude', 'plugins', 'installed_plugins.json'), installedJson({ 'flow@brain-plugins': [install('flow', 'user', '1.27.1'), install('flow', 'project', '1.11.0', ROOT)] }));
    mkdirSync(path.join(home, '.codex', 'plugins', 'cache', 'brain-plugins', 'flow', '1.9.2'), { recursive: true });
    mkdirSync(path.join(home, '.codex', 'plugins', 'cache', 'brain-plugins', 'flow', '1.10.0'), { recursive: true });
    writeFileSync(path.join(home, '.codex', 'config.toml'), '[plugins."flow@brain-plugins"]\nenabled = true\n');
    assert.deepEqual(await pluginReader(home)(ROOT, null), [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.11.0', codex: '1.10.0' }], 'because each host\'s version comes from its own files under the home');
  } finally { rmSync(home, { recursive: true, force: true }); }
});
