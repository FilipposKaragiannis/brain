import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** One row of `jobs.sh status --json`, as the flow plugin prints it. */
export type JobStatusRow = {
  job: string;
  schedule: string;
  args: string;
  installed: boolean;
  paused: boolean;
  loaded: boolean;
  running: { job: string; at: string }[];
  week: Record<string, number>;
  last: { at: string; seconds: number; exit: number | string | null; result: string; outcome: string } | null;
  next: string;
};

export type JobFacts = { jobs: JobStatusRow[] };

const JOBS_TIMEOUT_MS = 30000;

export function parseJobStatus(source: string): JobStatusRow[] {
  const parsed: unknown = JSON.parse(source);
  return Array.isArray(parsed) ? (parsed as JobStatusRow[]) : [];
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
  return { jobs: parseJobStatus(result.stdout) };
}
