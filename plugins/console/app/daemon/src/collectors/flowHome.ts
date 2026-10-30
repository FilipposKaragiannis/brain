import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { parseEvents } from '../events.ts';
import { EVENTS_KEPT } from '../snapshot.ts';
import { readSyncNote, reportsDir } from '../syncNote.ts';
import { parseYaml, yamlList, yamlMap, yamlString } from '../yaml.ts';
import type { YamlMap } from '../yaml.ts';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';
import type { FlowEvent, GatePlan, GateQuestion, PluginSource } from '../snapshot.ts';

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
  /** What in the file the console read but the plugin no longer does, such as the old `health.behind_base`. */
  deprecated: string[];
};

/**
 * One record in .flow/gates. `questions` is the plugin's own parse of the message, from
 * `gate.sh list --json` (flow 1.18.0 and later), so the console and Slack show the same card.
 * It is null when the plugin is older or the list failed, and the daemon parses the message.
 */
export type GateRecord = { item: string; gate: string; message: string; time: string; host: string; questions: GateQuestion[] | null; plan: GatePlan | null };
export type RunRecord = { item: string; step: string; profile: string; worktree: string; host: string; startedAt: string | null };
export type ClaimRecord = {
  worktreePath: string;
  item: string;
  branch: string;
  base: string;
  step: string;
  claimedAt: string;
  host: string;
  /** The refs the item's sync note names (`<worktree>/.flow/reports/<item>/sync.md`), or null with none. */
  syncPending: string[] | null;
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
  /** `FLOW_PLUGIN` when the daemon's environment names the plugin, `installed` when .flow/plugin.sh found it; null with no plugin. */
  pluginSource: PluginSource | null;
  /** Why `gate.sh list --json` gave no parse this read, or null when it was not needed or worked. */
  gateListError: string | null;
  /**
   * Whether each step of the plugin's step table (`steps.<step>.worktree` in its profiles.json,
   * what next.sh's `step_field <step> worktree` reads) runs in a claimed worktree; null when the
   * plugin or its table could not be read.
   */
  worktreeSteps: Record<string, boolean> | null;
};

const PLUGIN_LOOKUP_TIMEOUT_MS = 5000;
/** Short on purpose: the list only improves the parse, and the whole files source waits for it. */
const GATE_LIST_TIMEOUT_MS = 10000;
/** The first flow version whose `gate.sh list --json` exists. */
export const GATE_JSON_SINCE = '1.18.0';

/**
 * The plugin's parse per gate item, with the message it parsed. The list is asked only for a
 * gate whose message is not here yet, so a waiting gate costs no process after its first read.
 * One per project, owned by its monitor.
 */
export type GateQuestionCache = Map<string, { message: string; questions: GateQuestion[] }>;

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
  // The plugin reads jobs.health.behind_base (steward.sh). Console 0.5 read health.behind_base;
  // that still counts for one release, with a warning, when the new key is absent.
  const current = yamlString(map, 'jobs.health.behind_base');
  const legacy = yamlString(map, 'health.behind_base');
  const behindBase = current ?? legacy;
  const deprecated = current === null && legacy !== null ? ['health.behind_base is not read by the flow plugin; rename it to jobs.health.behind_base (the console reads the old key until 0.7.0)'] : [];
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
    deprecated,
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

/** The files a plan can be, in the order they win. */
const PLAN_FILES = ['plan.md', 'epic.md'];

/** The item's plan: the first of `PLAN_FILES` in its reports under each root in turn, or null. */
async function readPlan(roots: string[], item: string): Promise<GatePlan | null> {
  for (const root of roots) {
    for (const file of PLAN_FILES) {
      const text = await readText(path.join(reportsDir(root, item), file));
      if (text !== null && text.trim() !== '') return { file, text };
    }
  }
  return null;
}

async function readClaims(paths: string[]): Promise<ClaimRecord[]> {
  const claims: ClaimRecord[] = [];
  for (const worktreePath of paths) {
    const source = await readText(path.join(worktreePath, '.flow', 'claim.json'));
    if (source === null) continue;
    try {
      const value = JSON.parse(source) as Record<string, unknown>;
      const item = text(value, 'item');
      claims.push({
        worktreePath,
        item,
        branch: text(value, 'branch'),
        base: text(value, 'base'),
        step: text(value, 'step'),
        claimedAt: text(value, 'claimed_at'),
        host: text(value, 'host'),
        syncPending: item === '' ? null : await readSyncNote(worktreePath, item),
      });
    } catch { continue; }
  }
  return claims;
}

/**
 * Whether the plugin at `version` answers `gate.sh list --json`. A version that is not three
 * numbers (a dev checkout, say) is tried. An older plugin ignores the flag and prints its text
 * list with exit 0, which the reader reports as "printed no JSON array".
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

export type GateListEntry = { message: string; questions: GateQuestion[] };

/**
 * The questions per item out of `gate.sh list --json`, with the message they were parsed from.
 * A malformed question or entry is left out; output that is not a JSON array is null.
 */
export function parseGateList(source: string): Map<string, GateListEntry> | null {
  let parsed: unknown;
  try { parsed = JSON.parse(source); } catch { return null; }
  if (!Array.isArray(parsed)) return null;
  const entries = new Map<string, GateListEntry>();
  for (const entry of parsed as unknown[]) {
    if (typeof entry !== 'object' || entry === null) continue;
    const record = entry as Record<string, unknown>;
    if (typeof record['item'] !== 'string' || typeof record['message'] !== 'string' || !Array.isArray(record['questions'])) continue;
    const questions = (record['questions'] as unknown[]).map(gateQuestion).filter((question): question is GateQuestion => question !== null);
    entries.set(record['item'], { message: record['message'], questions });
  }
  return entries;
}

type GateListResult = { ok: true; entries: Map<string, GateListEntry> } | { ok: false; error: string };

async function readGateList(root: string, pluginRoot: string, runner: CommandRunner): Promise<GateListResult> {
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', 'gate.sh'), 'list', '--json'],
    cwd: root,
    timeoutMs: GATE_LIST_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  const said = result.stderr.trim().split('\n')[0] ?? '';
  if (result.timedOut) return { ok: false, error: `gate.sh list --json timed out after ${GATE_LIST_TIMEOUT_MS / 1000}s` };
  if (result.code !== 0) return { ok: false, error: `gate.sh list --json exited ${result.code}${said ? `: ${said}` : ''}` };
  const entries = parseGateList(result.stdout);
  if (entries === null) return { ok: false, error: 'gate.sh list --json printed no JSON array (a flow before 1.18.0 prints its text list)' };
  return { ok: true, entries };
}

/**
 * Fills `cache` for every record whose message it does not hold yet, and prunes the gates that
 * are gone. A list entry is paired with a record only when its message is the record's, so a
 * gate cleared and raised again between the two reads never shows the old text with new questions.
 */
async function fillGateQuestions(
  root: string, pluginRoot: string | null, pluginVersion: string | null, records: { item: string; message: string }[],
  runner: CommandRunner, cache: GateQuestionCache,
): Promise<string | null> {
  for (const item of [...cache.keys()]) {
    if (!records.some((record) => record.item === item)) cache.delete(item);
  }
  const missing = records.filter((record) => cache.get(record.item)?.message !== record.message);
  if (missing.length === 0 || pluginRoot === null || !pluginHasGateJson(pluginVersion)) return null;
  const list = await readGateList(root, pluginRoot, runner);
  if (!list.ok) return list.error;
  for (const record of missing) {
    const entry = list.entries.get(record.item);
    if (entry !== undefined && entry.message === record.message) cache.set(record.item, entry);
  }
  return null;
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

/**
 * The plugin's own version from its plugin.json, else the folder name. The installed cache names
 * the folder after the version; a checkout pointed at by FLOW_PLUGIN does not.
 */
export async function pluginVersionOf(pluginRoot: string): Promise<string> {
  const manifest = await readText(path.join(pluginRoot, '.claude-plugin', 'plugin.json'));
  if (manifest !== null) {
    try {
      const version = (JSON.parse(manifest) as { version?: unknown }).version;
      if (typeof version === 'string' && version.length > 0) return version;
    } catch { /* an unreadable manifest falls back to the folder name */ }
  }
  return path.basename(pluginRoot);
}

export async function readFlowHome(root: string, runner: CommandRunner, cache: GateQuestionCache = new Map()): Promise<FlowHomeFacts> {
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
  const pluginVersion = pluginRoot === null ? null : await pluginVersionOf(pluginRoot);
  const found = records.map(({ value }) => ({
    item: text(value, 'item'), gate: text(value, 'gate'), message: text(value, 'message'), time: text(value, 'time'), host: text(value, 'host'),
  }));
  const gateListError = await fillGateQuestions(root, pluginRoot, pluginVersion, found, runner, cache);
  const gates: GateRecord[] = found.map((gate) => {
    const cached = cache.get(gate.item);
    return { ...gate, questions: cached !== undefined && cached.message === gate.message ? cached.questions : null, plan: null };
  });
  for (const gate of gates) {
    const claimed = claims.find((claim) => claim.item === gate.item)?.worktreePath;
    gate.plan = await readPlan(claimed === undefined ? [root] : [claimed, root], gate.item);
  }
  const pluginSource: PluginSource | null = pluginRoot === null ? null : scriptEnvironment()['FLOW_PLUGIN'] !== undefined ? 'FLOW_PLUGIN' : 'installed';
  const worktreeSteps = pluginRoot === null ? null : await readWorktreeSteps(pluginRoot);
  return { flowHome, config, gates, runs, claims, events, pluginRoot, pluginVersion, pluginSource, gateListError, worktreeSteps };
}

/** The `worktree` flag of every step in the plugin's profiles.json, as next.sh's `step_field` reads it; null when unreadable. */
export async function readWorktreeSteps(pluginRoot: string): Promise<Record<string, boolean> | null> {
  const source = await readText(path.join(pluginRoot, 'profiles.json'));
  if (source === null) return null;
  try {
    const steps = (JSON.parse(source) as { steps?: unknown }).steps;
    if (typeof steps !== 'object' || steps === null) return null;
    return Object.fromEntries(Object.entries(steps as Record<string, unknown>).map(([name, step]) => [name, (step as { worktree?: unknown } | null)?.worktree === true]));
  } catch { return null; }
}
