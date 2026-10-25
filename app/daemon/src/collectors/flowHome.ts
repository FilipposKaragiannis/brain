import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { parseEvents } from '../events.ts';
import { EVENTS_KEPT } from '../snapshot.ts';
import { parseYaml, yamlList, yamlMap, yamlString } from '../yaml.ts';
import type { YamlMap } from '../yaml.ts';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';
import type { FlowEvent } from '../snapshot.ts';

/** The parts of .flow/config.yaml the snapshot needs. */
export type FlowConfig = {
  base: string;
  adapter: string;
  repo: string | null;
  pool: string[];
  poolMax: number | null;
  schedule: Record<string, string>;
  behindBase: number | null;
  /** jobs.host: the CLI the jobs run unattended, claude by default. */
  jobsHost: string;
};

export type GateRecord = { item: string; gate: string; message: string; time: string; host: string };
export type RunRecord = { item: string; step: string; profile: string; worktree: string; host: string; startedAt: string | null };
export type ClaimRecord = {
  worktreePath: string;
  item: string;
  branch: string;
  base: string;
  step: string;
  claimedAt: string;
  host: string;
};

export type FlowHomeFacts = {
  flowHome: string;
  config: FlowConfig;
  gates: GateRecord[];
  runs: RunRecord[];
  claims: ClaimRecord[];
  events: FlowEvent[];
  pluginRoot: string | null;
  pluginVersion: string | null;
};

const PLUGIN_LOOKUP_TIMEOUT_MS = 5000;

export function flowHomeOf(root: string): string {
  return path.join(root, '.flow');
}

export function poolPaths(root: string, config: FlowConfig): string[] {
  return config.pool.map((entry) => path.resolve(root, entry));
}

const JOB_HOSTS = ['claude', 'codex'];

function jobsHostOf(value: string | null): string {
  return value !== null && JOB_HOSTS.includes(value) ? value : 'claude';
}

export function parseFlowConfig(source: string): FlowConfig {
  const map: YamlMap = parseYaml(source);
  const poolMax = yamlString(map, 'pool_max');
  const behindBase = yamlString(map, 'health.behind_base');
  const schedule: Record<string, string> = {};
  for (const [job, value] of Object.entries(yamlMap(map, 'jobs.schedule'))) {
    if (typeof value === 'string') schedule[job] = value;
  }
  return {
    base: yamlString(map, 'base') ?? 'main',
    adapter: yamlString(map, 'adapters.default') ?? 'local',
    repo: yamlString(map, 'github.repo'),
    pool: yamlList(map, 'pool'),
    poolMax: poolMax === null ? null : Number(poolMax),
    schedule,
    behindBase: behindBase === null ? null : Number(behindBase),
    jobsHost: jobsHostOf(yamlString(map, 'jobs.host')),
  };
}

async function readText(file: string): Promise<string | null> {
  try { return await readFile(file, 'utf8'); } catch { return null; }
}

async function readJsonFiles(directory: string): Promise<{ file: string; value: Record<string, unknown>; modifiedAt: string }[]> {
  let names: string[];
  try { names = await readdir(directory); } catch { return []; }
  const out: { file: string; value: Record<string, unknown>; modifiedAt: string }[] = [];
  for (const name of names.filter((entry) => entry.endsWith('.json')).sort()) {
    const file = path.join(directory, name);
    const text = await readText(file);
    if (text === null) continue;
    try {
      const value = JSON.parse(text) as Record<string, unknown>;
      const info = await stat(file);
      out.push({ file, value, modifiedAt: info.mtime.toISOString() });
    } catch { continue; }
  }
  return out;
}

function text(value: Record<string, unknown>, key: string): string {
  const field = value[key];
  return typeof field === 'string' ? field : '';
}

async function readClaims(paths: string[]): Promise<ClaimRecord[]> {
  const claims: ClaimRecord[] = [];
  for (const worktreePath of paths) {
    const source = await readText(path.join(worktreePath, '.flow', 'claim.json'));
    if (source === null) continue;
    try {
      const value = JSON.parse(source) as Record<string, unknown>;
      claims.push({
        worktreePath,
        item: text(value, 'item'),
        branch: text(value, 'branch'),
        base: text(value, 'base'),
        step: text(value, 'step'),
        claimedAt: text(value, 'claimed_at'),
        host: text(value, 'host'),
      });
    } catch { continue; }
  }
  return claims;
}

/** The installed flow plugin the project uses, as .flow/plugin.sh resolves it. */
export async function findPluginRoot(root: string, runner: CommandRunner): Promise<string | null> {
  const result = await runner({
    command: 'sh',
    args: ['-c', '. .flow/plugin.sh && printf %s "$FLOW_PLUGIN"'],
    cwd: root,
    timeoutMs: PLUGIN_LOOKUP_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  const found = result.stdout.trim();
  return result.code === 0 && found.length > 0 ? found : null;
}

export async function readFlowHome(root: string, runner: CommandRunner): Promise<FlowHomeFacts> {
  const flowHome = flowHomeOf(root);
  const configSource = (await readText(path.join(flowHome, 'config.yaml'))) ?? '';
  const config = parseFlowConfig(configSource);
  const gates = (await readJsonFiles(path.join(flowHome, 'gates'))).map(({ value }) => ({
    item: text(value, 'item'), gate: text(value, 'gate'), message: text(value, 'message'), time: text(value, 'time'), host: text(value, 'host'),
  }));
  const runs = (await readJsonFiles(path.join(flowHome, 'runs'))).map(({ value, modifiedAt }) => ({
    item: text(value, 'item'), step: text(value, 'step'), profile: text(value, 'profile'), worktree: text(value, 'worktree'), host: text(value, 'host'), startedAt: modifiedAt,
  }));
  const claims = await readClaims([root, ...poolPaths(root, config)]);
  const events = parseEvents((await readText(path.join(flowHome, 'events.log'))) ?? '', EVENTS_KEPT);
  const pluginRoot = await findPluginRoot(root, runner);
  return {
    flowHome, config, gates, runs, claims, events, pluginRoot,
    pluginVersion: pluginRoot === null ? null : path.basename(pluginRoot),
  };
}
