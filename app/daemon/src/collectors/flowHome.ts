import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { parseEvents } from '../events.ts';
import { EVENTS_KEPT } from '../snapshot.ts';
import { parseYaml, yamlList, yamlMap, yamlString } from '../yaml.ts';
import type { YamlMap } from '../yaml.ts';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';
import type { FlowEvent, GateQuestion } from '../snapshot.ts';

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

/**
 * One record in .flow/gates. `questions` is the plugin's own parse of the message, from
 * `gate.sh list --json` (flow 1.18.0 and later), so the console and Slack show the same card.
 * It is null when the plugin is older or the list failed, and the daemon parses the message.
 */
export type GateRecord = { item: string; gate: string; message: string; time: string; host: string; questions: GateQuestion[] | null };
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
const GATE_LIST_TIMEOUT_MS = 30000;
/** The first flow version whose `gate.sh list --json` exists. */
export const GATE_JSON_SINCE = '1.18.0';

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

/**
 * Whether the plugin at `version` answers `gate.sh list --json`. A version that is not three
 * numbers (a dev checkout, say) is tried: the call fails cleanly when the flag is unknown.
 */
export function pluginHasGateJson(version: string | null): boolean {
  const parts = version?.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!parts) return true;
  const since = GATE_JSON_SINCE.split('.').map(Number);
  const have = parts.slice(1).map(Number);
  for (let index = 0; index < since.length; index += 1) {
    if (have[index]! !== since[index]!) return have[index]! > since[index]!;
  }
  return true;
}

function gateQuestion(value: unknown): GateQuestion | null {
  if (typeof value !== 'object' || value === null) return null;
  const record = value as Record<string, unknown>;
  const recommended = record['recommended'];
  if (typeof record['number'] !== 'number' || typeof record['text'] !== 'string') return null;
  if (recommended !== null && typeof recommended !== 'string') return null;
  return { number: record['number'], text: record['text'], recommended: recommended ?? null };
}

/** The questions per item out of `gate.sh list --json`. Anything that is not in shape is left out. */
export function parseGateList(source: string): Map<string, GateQuestion[]> {
  const questions = new Map<string, GateQuestion[]>();
  let parsed: unknown;
  try { parsed = JSON.parse(source); } catch { return questions; }
  if (!Array.isArray(parsed)) return questions;
  for (const entry of parsed as unknown[]) {
    if (typeof entry !== 'object' || entry === null) continue;
    const record = entry as Record<string, unknown>;
    if (typeof record['item'] !== 'string' || !Array.isArray(record['questions'])) continue;
    questions.set(record['item'], (record['questions'] as unknown[]).map(gateQuestion).filter((question): question is GateQuestion => question !== null));
  }
  return questions;
}

async function readGateQuestions(root: string, pluginRoot: string, runner: CommandRunner): Promise<Map<string, GateQuestion[]> | null> {
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', 'gate.sh'), 'list', '--json'],
    cwd: root,
    timeoutMs: GATE_LIST_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  return result.code === 0 ? parseGateList(result.stdout) : null;
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
  const records = await readJsonFiles(path.join(flowHome, 'gates'));
  const runs = (await readJsonFiles(path.join(flowHome, 'runs'))).map(({ value, modifiedAt }) => ({
    item: text(value, 'item'), step: text(value, 'step'), profile: text(value, 'profile'), worktree: text(value, 'worktree'), host: text(value, 'host'), startedAt: modifiedAt,
  }));
  const claims = await readClaims([root, ...poolPaths(root, config)]);
  const events = parseEvents((await readText(path.join(flowHome, 'events.log'))) ?? '', EVENTS_KEPT);
  const pluginRoot = await findPluginRoot(root, runner);
  const pluginVersion = pluginRoot === null ? null : path.basename(pluginRoot);
  const askPlugin = records.length > 0 && pluginRoot !== null && pluginHasGateJson(pluginVersion);
  const questions = askPlugin ? await readGateQuestions(root, pluginRoot, runner) : null;
  const gates: GateRecord[] = records.map(({ value }) => ({
    item: text(value, 'item'), gate: text(value, 'gate'), message: text(value, 'message'), time: text(value, 'time'), host: text(value, 'host'),
    questions: questions?.get(text(value, 'item')) ?? null,
  }));
  return { flowHome, config, gates, runs, claims, events, pluginRoot, pluginVersion };
}
