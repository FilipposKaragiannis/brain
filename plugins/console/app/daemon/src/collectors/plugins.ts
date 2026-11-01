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

/** One install of a plugin in Claude Code's installed_plugins.json. */
export type ClaudeInstall = { name: string; marketplace: string; scope: string; projectPath: string | null; version: string };
/** A plugin Codex's config enables, as `<name>@<marketplace>`. */
export type CodexEnabled = { name: string; marketplace: string };

/** Reads the hosts' plugin files for a project: its root and the flow plugin folder it resolves. */
export type PluginReader = (root: string, pluginRoot: string | null) => Promise<InstalledPlugin[]>;

/** No host files read: every project has no plugins. The monitor's default, so a test never reads the real home. */
export const noPlugins: PluginReader = async () => [];

function splitKey(key: string): { name: string; marketplace: string } | null {
  const at = key.lastIndexOf('@');
  return at <= 0 || at === key.length - 1 ? null : { name: key.slice(0, at), marketplace: key.slice(at + 1) };
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

/** The plugins `~/.codex/config.toml` enables: each `[plugins."<name>@<marketplace>"]` table with `enabled = true`. */
export function parseCodexEnabled(source: string | null): CodexEnabled[] {
  if (source === null) return [];
  const out: CodexEnabled[] = [];
  let current: CodexEnabled | null = null;
  for (const raw of source.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('[')) {
      const match = CODEX_PLUGIN_TABLE.exec(line);
      const key = match === null ? null : match[1] ?? match[2] ?? null;
      current = key === null ? null : splitKey(key);
      continue;
    }
    const enabled = CODEX_ENABLED.exec(line);
    if (current !== null && enabled !== null && enabled[1] === 'true' && !out.some((entry) => entry.name === current?.name && entry.marketplace === current.marketplace)) {
      out.push(current);
    }
  }
  return out;
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

/** The version installed for the project: its own install (project or local scope, at its root), else the user's; null with neither. */
function claudeVersionFor(installs: ClaudeInstall[], root: string): string | null {
  const own = installs.find((install) => install.scope !== 'user' && install.projectPath !== null && path.resolve(install.projectPath) === path.resolve(root));
  return (own ?? installs.find((install) => install.scope === 'user'))?.version ?? null;
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
 * flow's marketplace: that of Claude's flow install (the one for this project first), else of the
 * flow folder in the Codex cache (an enabled one first), else of the cache folder the project's
 * plugin sits in, else brain-plugins.
 */
export function flowMarketplace({ root, claude, codex, codexFlowMarketplaces, pluginRoot }: MarketplaceClues): string {
  const flows = claude.filter((install) => install.name === FLOW);
  const forProject = flows.find((install) => claudeVersionFor([install], root) !== null);
  const fromClaude = (forProject ?? flows[0])?.marketplace;
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
 * Reads the plugins of flow's marketplace from the hosts' files under `home`: Claude Code's
 * installed_plugins.json, Codex's config.toml and the version folders of the plugins it enables.
 * A missing or unreadable file counts as no plugins.
 */
export function pluginReader(home: string): PluginReader {
  return async (root, pluginRoot) => {
    const claude = parseClaudeInstalled(await readText(path.join(home, '.claude', 'plugins', 'installed_plugins.json')));
    const codex = parseCodexEnabled(await readText(path.join(home, '.codex', 'config.toml')));
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
