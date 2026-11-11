import type { JobsHost } from './schema.ts';

/** The roster's Claude names as codex takes them, as `host_codex_model` in the plugin's lib/host.sh maps them. */
const CODEX_FROM_ROSTER: Record<string, string> = { sonnet: 'gpt-6.1-terra', opus: 'gpt-6.1-sol', fable: 'gpt-6-astra', haiku: 'gpt-6-luna' };

/** A model name as codex takes it: a roster name becomes its catalog name, and any other passes through unchanged. */
export function codexModel(name: string): string {
  return CODEX_FROM_ROSTER[name] ?? name;
}

/**
 * The model and effort a host runs with, as the file sets them (null leaves the host's own
 * default), and the keys they come from: `jobs.<host>`, or `jobs` for the deprecated pair.
 */
export type JobsPair = { model: string | null; effort: string | null; from: string };
/** The pair each host runs with. */
export type JobsPairs = Record<JobsHost, JobsPair>;

/**
 * What the plugin (flow 1.20.0, `host_jobs_pair` in lib/host.sh) still takes from the deprecated
 * `jobs.model` or `jobs.effort` for a host whose `jobs.<host>` map is absent: the value it runs
 * with and the key it came from, or null when the host's own map is there or the old key is
 * empty. A codex model there is a roster name, mapped the way the plugin maps it.
 */
export function legacyJobsSetting(values: Record<string, unknown>, host: JobsHost, setting: 'model' | 'effort'): { value: string; from: string } | null {
  const map = asRecord(values['jobs']);
  if (map === null || map[host] !== undefined) return null;
  const old = map[setting];
  if (typeof old !== 'string' || old === '') return null;
  return { value: host === 'codex' && setting === 'model' ? codexModel(old) : old, from: `jobs.${setting}` };
}

/**
 * The pair a host runs with, as the plugin reads it (`host_jobs_pair` in lib/host.sh):
 * `jobs.<host>.model` and `.effort`, else the deprecated `jobs.model` and `jobs.effort` while
 * `jobs.<host>` is absent, else null.
 */
export function jobsPair(values: Record<string, unknown>, host: JobsHost): JobsPair {
  const hostMap = asRecord(values['jobs'])?.[host];
  const own = asRecord(hostMap) ?? {};
  return { model: jobsSetting(values, host, own, 'model'), effort: jobsSetting(values, host, own, 'effort'), from: hostMap === undefined ? 'jobs' : `jobs.${host}` };
}

/** One setting of a host's pair: the host's own non-empty value, else the deprecated one, else null. */
function jobsSetting(values: Record<string, unknown>, host: JobsHost, own: Record<string, unknown>, setting: 'model' | 'effort'): string | null {
  const value = own[setting];
  if (typeof value === 'string' && value !== '') return value;
  return legacyJobsSetting(values, host, setting)?.value ?? null;
}

/** A parsed value as a map, or null when it is a scalar, a list or null. */
function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
