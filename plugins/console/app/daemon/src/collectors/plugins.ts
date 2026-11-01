import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import type { InstalledPlugin } from '../snapshot.ts';

/** flow's marketplace when neither host's install nor the plugin's folder names one. */
export const DEFAULT_MARKETPLACE = 'brain-plugins';
const FLOW = 'flow';
/** A plugin under a host's cache: `.../plugins/cache/<marketplace>/flow/<version>`. */
const CACHED_FLOW = /[/\\]plugins[/\\]cache[/\\]([^/\\]+)[/\\]flow[/\\][^/\\]+[/\\]?$/;
/** A Codex config table that names a plugin: `[plugins."<name>@<marketplace>"]`. */
const CODEX_PLUGIN_TABLE = /^\[\s*plugins\.(?:"([^"]+)"|'([^']+)')\s*\]\s*(?:#.*)?$/;
const CODEX_ENABLED = /^enabled\s*=\s*(true|false)\s*(?:#.*)?$/;
const FOLDER_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** One install of a plugin in Claude Code's installed_plugins.json. */
export type ClaudeInstall = { name: string; marketplace: string; scope: string; projectPath: string | null; version: string };
/** A plugin Codex's config enables, as `<name>@<marketplace>`. */
export type CodexEnabled = { name: string; marketplace: string };
/** A plugin table in a Codex config, with the `enabled` value it sets. */
export type CodexSetting = CodexEnabled & { enabled: boolean };

/** Reads the hosts' plugin files for a project: its root and the flow plugin folder it resolves. */
export type PluginReader = (root: string, pluginRoot: string | null) => Promise<InstalledPlugin[]>;

/** No host files read: every project has no plugins. The monitor's default, so a test never reads the real home. */
export const noPlugins: PluginReader = async () => [];

function splitKey(key: string): { name: string; marketplace: string } | null {
  const at = key.lastIndexOf('@');
  const name = key.slice(0, at);
  const marketplace = key.slice(at + 1);
  return at < 0 || !FOLDER_NAME.test(name) || !FOLDER_NAME.test(marketplace) ? null : { name, marketplace };
}

/** Every install `~/.claude/plugins/installed_plugins.json` lists; nothing when it is missing or not that shape. */
export function parseClaudeInstalled(source: string | null): ClaudeInstall[] {
  if (source === null) return [];
  let parsed: unknown;
  try { parsed = JSON.parse(source); } catch { return []; }
  const plugins = typeof parsed === 'object' && parsed !== null ? (parsed as { plugins?: unknown }).plugins : undefined;
  if (typeof plugins !== 'object' || plugins === null) return [];
  const out: ClaudeInstall[] = [];
  for (const [key, entries] of Object.entries(plugins)) {
    const named = splitKey(key);
    if (named === null || !Array.isArray(entries)) continue;
    for (const entry of entries as unknown[]) {
      if (typeof entry !== 'object' || entry === null) continue;
      const { scope, projectPath, version } = entry as { scope?: unknown; projectPath?: unknown; version?: unknown };
      if (typeof scope !== 'string' || typeof version !== 'string' || version === '') continue;
      out.push({ ...named, scope, projectPath: typeof projectPath === 'string' ? projectPath : null, version });
    }
  }
  return out;
}

/** Each `[plugins."<name>@<marketplace>"]` table of a Codex config.toml that sets `enabled`, with the last value it sets. */
export function parseCodexPlugins(source: string | null): CodexSetting[] {
  if (source === null) return [];
  const settings = new Map<string, CodexSetting>();
  let current: { key: string; name: string; marketplace: string } | null = null;
  for (const raw of source.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('[')) {
      const match = CODEX_PLUGIN_TABLE.exec(line);
      const key = match === null ? null : match[1] ?? match[2] ?? null;
      const named = key === null ? null : splitKey(key);
      current = key === null || named === null ? null : { key, ...named };
      continue;
    }
    const enabled = CODEX_ENABLED.exec(line);
    if (current !== null && enabled !== null) {
      settings.set(current.key, { name: current.name, marketplace: current.marketplace, enabled: enabled[1] === 'true' });
    }
  }
  return [...settings.values()];
}

/** The plugins Codex enables for a project: the home config's settings, each overridden by the project config's for the same `<name>@<marketplace>`. */
export function mergeCodexPlugins(home: CodexSetting[], project: CodexSetting[]): CodexEnabled[] {
  const settings = new Map<string, CodexSetting>();
  for (const setting of [...home, ...project]) settings.set(`${setting.name}@${setting.marketplace}`, setting);
  return [...settings.values()].filter((setting) => setting.enabled).map(({ name, marketplace }) => ({ name, marketplace }));
}

/** The plugins one Codex config.toml enables: each `[plugins."<name>@<marketplace>"]` table whose last `enabled` is true. */
export function parseCodexEnabled(source: string | null): CodexEnabled[] {
  return mergeCodexPlugins(parseCodexPlugins(source), []);
}

/** Orders versions on their dotted numbers, as .flow/plugin.sh sorts them: 1.10.0 after 1.9.2. */
export function compareVersions(left: string, right: string): number {
  const a = left.split('.');
  const b = right.split('.');
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const x = Number.parseInt(a[index] ?? '0', 10);
    const y = Number.parseInt(b[index] ?? '0', 10);
    const difference = (Number.isNaN(x) ? 0 : x) - (Number.isNaN(y) ? 0 : y);
    if (difference !== 0) return difference;
  }
  return left.localeCompare(right);
}

export function newestVersion(versions: string[]): string | null {
  return [...versions].sort(compareVersions).at(-1) ?? null;
}

/** The install Claude Code loads for the project: its own (project or local scope, at its root), else the user's; another project's never. */
function claudeInstallFor(installs: ClaudeInstall[], root: string): ClaudeInstall | undefined {
  const own = installs.find((install) => install.scope !== 'user' && install.projectPath !== null && path.resolve(install.projectPath) === path.resolve(root));
  return own ?? installs.find((install) => install.scope === 'user');
}

/** The version installed for the project, from the install Claude Code loads there; null with none. */
function claudeVersionFor(installs: ClaudeInstall[], root: string): string | null {
  return claudeInstallFor(installs, root)?.version ?? null;
}

export type MarketplaceClues = {
  root: string;
  claude: ClaudeInstall[];
  codex: CodexEnabled[];
  /** The marketplaces whose Codex cache folder holds a flow folder. */
  codexFlowMarketplaces: string[];
  pluginRoot: string | null;
};

/**
 * flow's marketplace: that of the flow install Claude Code loads for the project (its own at the
 * root first, else the user's; another project's never decides), else of the flow folder in the
 * Codex cache (an enabled one first), else of the cache folder the project's plugin sits in, else
 * brain-plugins.
 */
export function flowMarketplace({ root, claude, codex, codexFlowMarketplaces, pluginRoot }: MarketplaceClues): string {
  const fromClaude = claudeInstallFor(claude.filter((install) => install.name === FLOW), root)?.marketplace;
  if (fromClaude !== undefined) return fromClaude;
  const cached = [...codexFlowMarketplaces].sort();
  const fromCodex = cached.find((marketplace) => codex.some((entry) => entry.name === FLOW && entry.marketplace === marketplace)) ?? cached[0];
  if (fromCodex !== undefined) return fromCodex;
  const fromFolder = pluginRoot === null ? null : CACHED_FLOW.exec(pluginRoot)?.[1] ?? null;
  return fromFolder ?? DEFAULT_MARKETPLACE;
}

export type PluginClues = {
  root: string;
  marketplace: string;
  claude: ClaudeInstall[];
  codex: CodexEnabled[];
  /** The version folders in the Codex cache of each plugin of the marketplace, by name. */
  codexVersions: Record<string, string[]>;
};

/** The marketplace's plugins either host has for the project, by name, with each host's version. */
export function installedPlugins({ root, marketplace, claude, codex, codexVersions }: PluginClues): InstalledPlugin[] {
  const ours = claude.filter((install) => install.marketplace === marketplace);
  const enabled = new Set(codex.filter((entry) => entry.marketplace === marketplace).map((entry) => entry.name));
  const names = [...new Set([...ours.map((install) => install.name), ...enabled])].sort();
  return names.flatMap((name) => {
    const claudeVersion = claudeVersionFor(ours.filter((install) => install.name === name), root);
    const codexVersion = enabled.has(name) ? newestVersion(codexVersions[name] ?? []) : null;
    return claudeVersion === null && codexVersion === null ? [] : [{ name, marketplace, claude: claudeVersion, codex: codexVersion }];
  });
}

async function readText(file: string): Promise<string | null> {
  try { return await readFile(file, 'utf8'); } catch { return null; }
}

async function folders(folder: string): Promise<string[]> {
  try { return (await readdir(folder, { withFileTypes: true })).filter((entry) => entry.isDirectory()).map((entry) => entry.name); } catch { return []; }
}

/**
 * Reads the plugins of flow's marketplace from the hosts' files: Claude Code's
 * installed_plugins.json under `home`, Codex's config.toml under `home` with the one under the
 * project root over it, and the version folders under `home` of the plugins they enable.
 * A missing or unreadable file counts as no plugins.
 */
export function pluginReader(home: string): PluginReader {
  return async (root, pluginRoot) => {
    const claude = parseClaudeInstalled(await readText(path.join(home, '.claude', 'plugins', 'installed_plugins.json')));
    const codex = mergeCodexPlugins(
      parseCodexPlugins(await readText(path.join(home, '.codex', 'config.toml'))),
      parseCodexPlugins(await readText(path.join(root, '.codex', 'config.toml'))),
    );
    const cache = path.join(home, '.codex', 'plugins', 'cache');
    const codexFlowMarketplaces: string[] = [];
    for (const marketplace of await folders(cache)) {
      if ((await folders(path.join(cache, marketplace))).includes(FLOW)) codexFlowMarketplaces.push(marketplace);
    }
    const marketplace = flowMarketplace({ root, claude, codex, codexFlowMarketplaces, pluginRoot });
    const codexVersions: Record<string, string[]> = {};
    for (const entry of codex.filter((enabled) => enabled.marketplace === marketplace)) {
      codexVersions[entry.name] = await folders(path.join(cache, marketplace, entry.name));
    }
    return installedPlugins({ root, marketplace, claude, codex, codexVersions });
  };
}
