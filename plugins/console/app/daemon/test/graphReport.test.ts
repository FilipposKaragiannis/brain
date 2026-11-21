import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CancellableCommandRunner } from '../src/collectors/exec.ts';
import { GRAPH_REPORT_SCRIPT, GRAPH_REPORT_SINCE, readGraphReport } from '../src/collectors/graphReport.ts';
import type { GraphReport, GraphReportSource } from '../src/collectors/graphReport.ts';
import { FAKE_PLUGIN, FIXTURE_ROOT, fakeGraphReportWithoutHistory, fakeRunner, GRAPH_REPORT_DAILY, GRAPH_REPORT_MARKDOWN } from './fakeRunner.ts';

/** The fixture project with a plugin whose scripts could not be listed, and with the scripts given. */
const SOURCE: GraphReportSource = { projectRoot: FIXTURE_ROOT, pluginRoot: FAKE_PLUGIN, pluginScripts: null };
const withScripts = (pluginScripts: string[]): GraphReportSource => ({ ...SOURCE, pluginScripts });
/** A page that stays: its read is never cancelled. */
const staying = (): AbortSignal => new AbortController().signal;

/** The Markdown of a report that was read, or null. */
const markdownOf = (report: GraphReport): string | null => (report.ok ? report.markdown : null);
/** Why a report could not be read, or null when it was. */
const errorOf = (report: GraphReport): string | null => (report.ok ? null : report.error);
/** The daily lines of a report that was read, or null. */
const dailyOf = (report: GraphReport): unknown => (report.ok ? report.daily : null);
/** A script that prints the given text for the report with its daily lines. */
const printing = (stdout: string): CancellableCommandRunner => async () => ({ code: 0, stdout, stderr: '', timedOut: false });

test('GraphReport_FlowPrintsItsDailyLines_ReadsThemBesideTheMarkdown', async () => {
  const report = await readGraphReport(SOURCE, fakeRunner, staying());
  assert.deepEqual(dailyOf(report), GRAPH_REPORT_DAILY, 'because the page draws its chart from the days the flow kept');
});

test('GraphReport_FlowFromBeforeTheDailyLines_ReadsTheMarkdownAlone', async () => {
  const report = await readGraphReport(SOURCE, async (request) => fakeGraphReportWithoutHistory(request), staying());
  assert.deepEqual([markdownOf(report), dailyOf(report)], [GRAPH_REPORT_MARKDOWN, []], 'because an older flow still has a report to show, only no chart');
});

test('GraphReport_DailyLineWithANumberMissing_IsLeftOut', async () => {
  const whole = GRAPH_REPORT_DAILY[0];
  const broken = { day: '2026-10-23', step: 'verify', runs: 2 };
  const report = await readGraphReport(SOURCE, printing(JSON.stringify({ markdown: GRAPH_REPORT_MARKDOWN, daily: [broken, whole] })), staying());
  assert.deepEqual(dailyOf(report), [whole], 'because a point with no time cannot be drawn, and the rest of the chart still can');
});

test('GraphReport_ScriptPrintsSomethingThatIsNoReport_ErrorSaysSo', async () => {
  const report = await readGraphReport(SOURCE, printing('not a report'), staying());
  assert.match(errorOf(report) ?? '', /printed no report/, 'because the page must say the report is missing instead of showing an empty one');
});

test('GraphReport_ScriptPrintsAReport_ReadAsItsMarkdown', async () => {
  const report = await readGraphReport(SOURCE, fakeRunner, staying());
  assert.equal(markdownOf(report), GRAPH_REPORT_MARKDOWN, 'because the fake script answers only a seven-day report asked from the project root, and the page renders what it printed');
});

test('GraphReport_PluginListsTheScript_ReadAsItsMarkdown', async () => {
  const report = await readGraphReport(withScripts(['board.sh', GRAPH_REPORT_SCRIPT, 'jobs.sh']), fakeRunner, staying());
  assert.equal(markdownOf(report), GRAPH_REPORT_MARKDOWN, 'because a plugin that holds the script is asked for the report');
});

test('GraphReport_PluginWithoutTheScript_ErrorNamesTheFlowItNeeds', async () => {
  const report = await readGraphReport(withScripts(['board.sh', 'jobs.sh']), fakeRunner, staying());
  assert.match(errorOf(report) ?? '', new RegExp(`needs flow ${GRAPH_REPORT_SINCE.replaceAll('.', '\\.')}`), 'because an older flow has no such script, and the owner must hear which flow has it instead of a shell error');
});

test('GraphReport_ScriptFails_ErrorCarriesWhatTheScriptSaid', async () => {
  const failing: CancellableCommandRunner = async () => ({ code: 2, stdout: '', stderr: 'flow: no .flow in /somewhere\n', timedOut: false });
  const report = await readGraphReport(SOURCE, failing, staying());
  assert.match(errorOf(report) ?? '', /no \.flow in \/somewhere/, 'because the page shows the script\'s own reason');
});

test('GraphReport_ScriptPrintsNothingToStderr_ErrorCarriesItsExitCode', async () => {
  const silent: CancellableCommandRunner = async () => ({ code: 3, stdout: '', stderr: '', timedOut: false });
  const report = await readGraphReport(SOURCE, silent, staying());
  assert.match(errorOf(report) ?? '', /exit 3/, 'because a failure with no words still needs something the owner can search for');
});

test('GraphReport_ScriptRunsTooLong_ErrorSaysSo', async () => {
  const stuck: CancellableCommandRunner = async () => ({ code: null, stdout: '', stderr: '', timedOut: true });
  const report = await readGraphReport(SOURCE, stuck, staying());
  assert.match(errorOf(report) ?? '', /ran too long/, 'because a killed script has no exit code and no words of its own');
});

test('GraphReport_PageLeavesWhileTheScriptRuns_ReadEndsCancelled', async () => {
  const leaving = new AbortController();
  const runsUntilCancelled: CancellableCommandRunner = (_request, signal) => new Promise((resolve) => {
    signal.addEventListener('abort', () => resolve({ code: null, stdout: '', stderr: '', timedOut: false }));
  });
  const reading = readGraphReport(SOURCE, runsUntilCancelled, leaving.signal);
  leaving.abort();
  assert.match(errorOf(await reading) ?? '', /cancelled/, 'because the script must end when nobody waits for it, not run on to its time limit');
});
