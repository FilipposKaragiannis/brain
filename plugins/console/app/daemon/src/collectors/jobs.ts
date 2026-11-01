import { open } from 'node:fs/promises';
import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';
import { flowHomeOf } from './flowHome.ts';
import { scheduleJob } from '../plugins/flow/schema.ts';

/**
 * One line of `<flow home>/log/runs.jsonl` that a job wrote (`job_record` in the plugin's
 * jobs/_job.sh): the schedule (`next-nightly`; `next-2` or `next-nightly-2` for a worker), the host, the start, the length, the
 * exit and the last thing it said. `outcome` and `reason` are flow's own, when a reader of flow
 * (`jobs.sh status`) added them; the file's own lines carry neither.
 */
export type JobRunRecord = {
  job: string;
  host?: string;
  at: string;
  seconds: number;
  exit: number | string | null;
  result: string;
  outcome?: string;
  reason?: string;
};

/** A run as `jobs.sh status --json` reports it (`last`, a worker's `last_run`): a run log line, whose job a plugin before 1.24.0 may leave out. */
export type JobStatusRun = Omit<JobRunRecord, 'job'> & { job?: string };

/** A live run of a job, as `jobs.sh status --json` lists it; pid and host since flow 1.24.0. */
export type JobRunningRow = { job: string; at: string; pid?: number; host?: string };

/** One worker of the next job, as `jobs.sh status --json` lists it (flow 1.24.0 and later). */
export type JobWorkerRow = { job: string; host: string; running: JobRunningRow | null; last_run: JobStatusRun | null };

/**
 * One row of `jobs.sh status --json`, as the flow plugin prints it, with what an older plugin
 * leaves out filled in by `parseJobStatus`.
 */
export type JobStatusRow = {
  /** The schedule's name: a job, or `<job>-<label>` (`next-nightly`). */
  name: string;
  /** The job the schedule runs, the script's name (`next` for `next-nightly`). */
  job: string;
  /** The host the schedule runs on; null when the plugin does not say. */
  host: string | null;
  /** False for an installed schedule the config no longer names; true when the plugin does not say. */
  configured: boolean;
  schedule: string;
  args: string;
  installed: boolean;
  paused: boolean;
  loaded: boolean;
  running: JobRunningRow[];
  week: Record<string, number>;
  last: JobStatusRun | null;
  next: string;
  /** The next job's workers (flow 1.24.0 and later); absent on other jobs and older plugins. */
  workers?: JobWorkerRow[];
};

/** `runs`: the job lines at the end of runs.jsonl, oldest first, as `readRunTail` read them. */
export type JobFacts = { jobs: JobStatusRow[]; runs: JobRunRecord[] };

const JOBS_TIMEOUT_MS = 30000;
/**
 * How much of the end of runs.jsonl a read takes. The file grows to 4000 lines before flow rotates
 * it, and the host's step lines (with their usage) sit among the job lines, so a whole read would
 * cost far more than the dozen runs per job the snapshot keeps.
 */
export const RUNS_TAIL_BYTES = 1024 * 1024;
const RUNS_FILE = 'runs.jsonl';
/** Where `job_record` moves runs.jsonl at 4000 lines; read only when the current file is shorter than the tail. */
const RUNS_ROTATED_FILE = 'runs.1.jsonl';

/**
 * The rows of `jobs.sh status --json`. Each names its schedule and the job (the script) it runs:
 * a row with a `name` holds the schedule there and the job in `job`; a row without one holds the
 * schedule in `job`, and the job is its name up to the label, which on a plugin before named
 * schedules is the name itself. `host` (null when absent or empty) and `configured` (true when
 * absent) came with named schedules too.
 */
export function parseJobStatus(source: string): JobStatusRow[] {
  const parsed: unknown = JSON.parse(source);
  if (!Array.isArray(parsed)) return [];
  return (parsed as (Omit<JobStatusRow, 'name' | 'host' | 'configured'> & { name?: unknown; host?: unknown; configured?: unknown })[]).map((row) => {
    const named = typeof row.name === 'string' && row.name !== '';
    const name = named ? row.name as string : row.job;
    return {
      ...row, name, job: named && typeof row.job === 'string' && row.job !== '' ? row.job : scheduleJob(name),
      host: typeof row.host === 'string' && row.host !== '' ? row.host : null, configured: row.configured !== false,
    };
  });
}

/**
 * The job lines of runs.jsonl text, in file order. A line that is not JSON, not an object or has
 * no job name (the host's step lines, `host_record`, have none) is passed over, as flow's own
 * `_jobs.py runs` does.
 */
export function parseRunLines(text: string): JobRunRecord[] {
  const out: JobRunRecord[] = [];
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue;
    let parsed: unknown;
    try { parsed = JSON.parse(line); } catch { continue; }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) continue;
    const record = parsed as Record<string, unknown>;
    if (typeof record['job'] !== 'string' || record['job'] === '') continue;
    out.push({
      job: record['job'],
      ...(typeof record['host'] === 'string' ? { host: record['host'] } : {}),
      at: typeof record['at'] === 'string' ? record['at'] : '',
      seconds: typeof record['seconds'] === 'number' ? record['seconds'] : 0,
      exit: typeof record['exit'] === 'number' || typeof record['exit'] === 'string' ? record['exit'] : null,
      // A record before flow 1.20.2 holds a result of digits as a number.
      result: record['result'] === undefined || record['result'] === null ? '' : String(record['result']),
      ...(typeof record['outcome'] === 'string' ? { outcome: record['outcome'] } : {}),
      ...(typeof record['reason'] === 'string' ? { reason: record['reason'] } : {}),
    });
  }
  return out;
}

/** The last `bytes` of a file, with the cut first line dropped, and the file's size; null when it cannot be read. */
async function fileTail(file: string, bytes: number): Promise<{ text: string; size: number } | null> {
  let handle;
  try { handle = await open(file, 'r'); } catch { return null; }
  try {
    const { size } = await handle.stat();
    const length = Math.min(size, bytes);
    if (length <= 0) return { text: '', size };
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    const text = buffer.toString('utf8');
    return { text: length < size ? text.slice(text.indexOf('\n') + 1) : text, size };
  } catch { return null; } finally { await handle.close(); }
}

/**
 * The job lines at the end of `<log dir>/runs.jsonl`, oldest first, reading at most `bytes` of it.
 * When the file is shorter than that (it was rotated not long ago), the rest of the budget goes to
 * the end of runs.1.jsonl before it, as flow reads the two files in turn.
 */
export async function readRunTail(logDir: string, bytes = RUNS_TAIL_BYTES): Promise<JobRunRecord[]> {
  const current = await fileTail(path.join(logDir, RUNS_FILE), bytes);
  const left = bytes - (current?.size ?? 0);
  const rotated = left > 0 ? await fileTail(path.join(logDir, RUNS_ROTATED_FILE), left) : null;
  return [...parseRunLines(rotated?.text ?? ''), ...parseRunLines(current?.text ?? '')];
}

export async function readJobs(root: string, pluginRoot: string, runner: CommandRunner): Promise<JobFacts> {
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', 'jobs.sh'), 'status', '--json'],
    cwd: root,
    timeoutMs: JOBS_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  if (result.code !== 0) throw new Error(`jobs.sh status failed: ${result.stderr.trim() || result.code}`);
  return { jobs: parseJobStatus(result.stdout), runs: await readRunTail(path.join(flowHomeOf(root), 'log')) };
}
