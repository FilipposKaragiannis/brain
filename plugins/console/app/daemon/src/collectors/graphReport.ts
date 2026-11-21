import path from 'node:path';
import type { CancellableCommandRunner, CommandResult } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** How many days the report covers, compared with as many days before: the retro job's period. */
export const GRAPH_REPORT_DAYS = 7;
/** The flow script that prints the report, and the first flow version that holds it. */
export const GRAPH_REPORT_SCRIPT = 'graph-report.sh';
export const GRAPH_REPORT_SINCE = '1.44.0';
const GRAPH_REPORT_TIMEOUT_MS = 30000;
/** What the script exits with for an option it does not know: a flow from before `--json`. */
const USAGE_EXIT = 2;

declare const meaning: unique symbol;
/** A string or a number that carries what it means in its type, so one meaning is never passed for another. */
type Meaning<Value, Name extends string> = Value & { readonly [meaning]: Name };
/** A UTC day as `2026-11-20`. */
export type IsoDay = Meaning<string, 'IsoDay'>;
/** A step of the flow, by its name in profiles.json. */
export type StepName = Meaning<string, 'StepName'>;
export type Seconds = Meaning<number, 'Seconds'>;
export type RunCount = Meaning<number, 'RunCount'>;
export type ItemCount = Meaning<number, 'ItemCount'>;
export type Dollars = Meaning<number, 'Dollars'>;

/**
 * One day of one step in the flow's history, as `graph-report.sh --json` prints it: how many
 * runs the step had that day (UTC), the time they took in all, their median and the time nine in
 * ten finished within, the failed runs, the cost and the items they worked on.
 */
export type StepDay = Readonly<{ day: IsoDay; step: StepName; runs: RunCount; seconds: Seconds; median: Seconds; within: Seconds; failed: RunCount; cost: Dollars; items: ItemCount }>;

/**
 * The flow's graph report of a project: what each step cost in the last days, which steps got
 * slower against the days before, and the items that took the most step time, as the Markdown
 * `scripts/graph-report.sh` prints, with the daily lines of the last 30 days the page draws its
 * chart from (none from a flow that keeps no history yet). A report that cannot be read is a
 * value that says why.
 */
export type GraphReport = Readonly<{ ok: true; days: number; markdown: string; daily: readonly StepDay[] }> | Readonly<{ ok: false; error: string }>;

/**
 * Where a project's graph report is read from: the project whose run log the script reads, the
 * flow plugin whose script runs, and that plugin's script names, null when they could not be
 * listed.
 */
export type GraphReportSource = { projectRoot: string; pluginRoot: string; pluginScripts: string[] | null };

const DAILY_NUMBERS = ['runs', 'seconds', 'median', 'within', 'failed', 'cost', 'items'] as const;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

function isStepDay(line: unknown): line is StepDay {
  if (typeof line !== 'object' || line === null) return false;
  const fields = line as Record<string, unknown>;
  const named = typeof fields.day === 'string' && ISO_DAY.test(fields.day) && typeof fields.step === 'string' && fields.step !== '';
  return named && DAILY_NUMBERS.every((name) => {
    const value = fields[name];
    return typeof value === 'number' && Number.isFinite(value) && value >= 0;
  });
}

function parseStructuredReport(output: string): { markdown: string; daily: readonly StepDay[] } | null {
  let printed: unknown;
  try { printed = JSON.parse(output); } catch { return null; }
  if (typeof printed !== 'object' || printed === null) return null;
  const { markdown, daily } = printed as { markdown?: unknown; daily?: unknown };
  if (typeof markdown !== 'string') return null;
  return { markdown, daily: Array.isArray(daily) ? daily.filter(isStepDay) : [] };
}

function failure(result: CommandResult): GraphReport {
  const why = result.timedOut ? 'it ran too long' : result.stderr.trim() || `exit ${result.code}`;
  return { ok: false, error: `${GRAPH_REPORT_SCRIPT} failed: ${why}` };
}

const CANCELLED: GraphReport = { ok: false, error: 'the read was cancelled' };

/**
 * Runs the flow's graph-report.sh from the project root. The script reads the run log under the
 * flow home and keeps the finished days of it in the flow's history file. It is asked for the
 * report with its daily lines; a flow from before those answers with its usage, and is then asked
 * for the Markdown alone. A plugin known to have no such script is not run, and `signal` ends a
 * script nobody waits for any more.
 */
export async function readGraphReport(source: GraphReportSource, runner: CancellableCommandRunner, signal: AbortSignal): Promise<GraphReport> {
  if (source.pluginScripts !== null && !source.pluginScripts.includes(GRAPH_REPORT_SCRIPT)) {
    return { ok: false, error: `the installed flow has no graph report: it needs flow ${GRAPH_REPORT_SINCE} or later` };
  }
  const ask = (options: string[]): Promise<CommandResult> => runner({
    command: 'sh',
    args: [path.join(source.pluginRoot, 'scripts', GRAPH_REPORT_SCRIPT), '--days', String(GRAPH_REPORT_DAYS), ...options],
    cwd: source.projectRoot,
    timeoutMs: GRAPH_REPORT_TIMEOUT_MS,
    env: scriptEnvironment(),
  }, signal);
  const structured = await ask(['--json']);
  if (signal.aborted) return CANCELLED;
  if (structured.code === USAGE_EXIT) return readMarkdownAlone(await ask([]), signal);
  if (structured.code !== 0) return failure(structured);
  const report = parseStructuredReport(structured.stdout);
  return report === null ? { ok: false, error: `${GRAPH_REPORT_SCRIPT} printed no report` } : { ok: true, days: GRAPH_REPORT_DAYS, ...report };
}

function readMarkdownAlone(plain: CommandResult, signal: AbortSignal): GraphReport {
  if (signal.aborted) return CANCELLED;
  return plain.code === 0 ? { ok: true, days: GRAPH_REPORT_DAYS, markdown: plain.stdout, daily: [] } : failure(plain);
}
