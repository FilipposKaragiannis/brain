import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** How many days the report covers, compared with as many days before: the retro job's period. */
export const GRAPH_REPORT_DAYS = 7;
/** The flow script that prints the report, and the first flow version that holds it. */
export const GRAPH_REPORT_SCRIPT = 'graph-report.sh';
export const GRAPH_REPORT_SINCE = '1.44.0';
const GRAPH_REPORT_TIMEOUT_MS = 30000;

/**
 * The flow's graph report of a project: what each step cost in the last days, which steps got
 * slower against the days before, and the items that took the most step time, as the Markdown
 * `scripts/graph-report.sh` prints. A report that cannot be read is a value that says why.
 */
export type GraphReport = { ok: true; days: number; markdown: string } | { ok: false; error: string };

/**
 * Runs the flow's graph-report.sh from the project root. The script reads the run log under the
 * flow home and changes nothing. `pluginScripts` is the plugin's script names, null when they
 * could not be listed: a plugin known to have no such script is not run.
 */
export async function readGraphReport(root: string, pluginRoot: string, pluginScripts: string[] | null, runner: CommandRunner): Promise<GraphReport> {
  if (pluginScripts !== null && !pluginScripts.includes(GRAPH_REPORT_SCRIPT)) {
    return { ok: false, error: `the installed flow has no graph report: it needs flow ${GRAPH_REPORT_SINCE} or later` };
  }
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', GRAPH_REPORT_SCRIPT), '--days', String(GRAPH_REPORT_DAYS)],
    cwd: root,
    timeoutMs: GRAPH_REPORT_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  if (result.code !== 0) {
    const why = result.timedOut ? 'it ran too long' : result.stderr.trim() || `exit ${result.code}`;
    return { ok: false, error: `${GRAPH_REPORT_SCRIPT} failed: ${why}` };
  }
  return { ok: true, days: GRAPH_REPORT_DAYS, markdown: result.stdout };
}
