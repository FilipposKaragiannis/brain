import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { compareVersions, flowMarketplace, installedPlugins, mergeCodexPlugins, parseClaudeInstalled, parseCodexEnabled, parseCodexPlugins, pluginReader } from '../src/collectors/plugins.ts';
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

test('FlowMarketplace_UserInstallFromOtherMarketplaceListedFirst_ProjectInstallsMarketplace', () => {
  const claude = claudeOf({ 'flow@user-market': [install('flow', 'user', '1.27.1')], 'flow@project-market': [install('flow', 'project', '1.11.0', ROOT)] });
  assert.equal(flowMarketplace({ root: ROOT, claude, codex: [], codexFlowMarketplaces: [], pluginRoot: null }), 'project-market', 'because the project\'s own flow install is what Claude Code loads there, over a user one listed before it');
});

test('FlowMarketplace_OnlyAnotherProjectsInstall_FallsToCodexCache', () => {
  const claude = claudeOf({ 'flow@other-market': [install('flow', 'project', '1.10.0', '/work/projects/other')] });
  assert.equal(flowMarketplace({ root: ROOT, claude, codex: [], codexFlowMarketplaces: ['theirs'], pluginRoot: null }), 'theirs', 'because another project\'s install says nothing of this one, so the next clue decides');
});

test('CodexSettings_ProjectEnablesWhatHomeDoesNot_Enabled', () => {
  const home = parseCodexPlugins('[plugins."flow@brain-plugins"]\nenabled = true\n');
  const project = parseCodexPlugins('[plugins."standards@brain-plugins"]\nenabled = true\n');
  assert.deepEqual(mergeCodexPlugins(home, project), [{ name: 'flow', marketplace: 'brain-plugins' }, { name: 'standards', marketplace: 'brain-plugins' }], 'because Codex reads the project\'s config.toml on top of the home one');
});

test('CodexSettings_ProjectDisablesWhatHomeEnables_NotEnabled', () => {
  const home = parseCodexPlugins('[plugins."flow@brain-plugins"]\nenabled = true\n[plugins."meta@brain-plugins"]\nenabled = true\n');
  const project = parseCodexPlugins('[plugins."flow@brain-plugins"]\nenabled = false\n');
  assert.deepEqual(mergeCodexPlugins(home, project), [{ name: 'meta', marketplace: 'brain-plugins' }], 'because the project\'s setting for a plugin overrides the home\'s');
});

test('CodexSettings_ProjectTableWithoutEnabled_HomeSettingKept', () => {
  const home = parseCodexPlugins('[plugins."flow@brain-plugins"]\nenabled = true\n');
  const project = parseCodexPlugins('[plugins."flow@brain-plugins"]\n# no enabled line\n');
  assert.deepEqual(mergeCodexPlugins(home, project), [{ name: 'flow', marketplace: 'brain-plugins' }], 'because a table that sets nothing overrides nothing');
});

test('CodexConfig_EnabledTwiceInATable_LastWins', () => {
  assert.deepEqual(parseCodexEnabled('[plugins."flow@brain-plugins"]\nenabled = true\nenabled = false\n'), [], 'because the last enabled line of a table is the one that holds');
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

function writeCodexConfig(folder: string, source: string): void {
  mkdirSync(path.join(folder, '.codex'), { recursive: true });
  writeFileSync(path.join(folder, '.codex', 'config.toml'), source);
}

test('PluginReader_ProjectConfigEnablesPluginHomeDoesNot_Listed', async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), 'plugins-home-'));
  const root = mkdtempSync(path.join(os.tmpdir(), 'plugins-root-'));
  try {
    mkdirSync(path.join(home, '.codex', 'plugins', 'cache', 'brain-plugins', 'standards', '1.4.0'), { recursive: true });
    writeCodexConfig(home, '[plugins."standards@brain-plugins"]\nenabled = false\n');
    writeCodexConfig(root, '[plugins."standards@brain-plugins"]\nenabled = true\n');
    assert.deepEqual(await pluginReader(home)(root, null), [{ name: 'standards', marketplace: 'brain-plugins', claude: null, codex: '1.4.0' }], 'because Codex enables a plugin the project\'s config.toml enables, with its version from the home cache');
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  }
});

test('PluginReader_ProjectConfigDisablesPluginHomeEnables_NotListed', async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), 'plugins-home-'));
  const root = mkdtempSync(path.join(os.tmpdir(), 'plugins-root-'));
  try {
    mkdirSync(path.join(home, '.codex', 'plugins', 'cache', 'brain-plugins', 'standards', '1.4.0'), { recursive: true });
    writeCodexConfig(home, '[plugins."standards@brain-plugins"]\nenabled = true\n');
    writeCodexConfig(root, '[plugins."standards@brain-plugins"]\nenabled = false\n');
    assert.deepEqual(await pluginReader(home)(root, null), [], 'because the project\'s enabled = false overrides the home\'s for that plugin');
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  }
});
