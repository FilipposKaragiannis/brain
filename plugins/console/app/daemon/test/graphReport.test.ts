import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandRunner } from '../src/collectors/exec.ts';
import { GRAPH_REPORT_SCRIPT, GRAPH_REPORT_SINCE, readGraphReport } from '../src/collectors/graphReport.ts';
import type { GraphReport } from '../src/collectors/graphReport.ts';
import { FAKE_PLUGIN, FIXTURE_ROOT, fakeRunner, GRAPH_REPORT_MARKDOWN } from './fakeRunner.ts';

/** The Markdown of a report that was read, or null. */
const markdownOf = (report: GraphReport): string | null => (report.ok ? report.markdown : null);
/** Why a report could not be read, or null when it was. */
const errorOf = (report: GraphReport): string | null => (report.ok ? null : report.error);

test('GraphReport_ScriptPrintsAReport_ReadAsItsMarkdown', async () => {
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, null, fakeRunner);
  assert.equal(markdownOf(report), GRAPH_REPORT_MARKDOWN, 'because the fake script answers only a seven-day report asked from the project root, and the page renders what it printed');
});

test('GraphReport_PluginListsTheScript_ReadAsItsMarkdown', async () => {
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, ['board.sh', GRAPH_REPORT_SCRIPT, 'jobs.sh'], fakeRunner);
  assert.equal(markdownOf(report), GRAPH_REPORT_MARKDOWN, 'because a plugin that holds the script is asked for the report');
});

test('GraphReport_PluginWithoutTheScript_ErrorNamesTheFlowItNeeds', async () => {
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, ['board.sh', 'jobs.sh'], fakeRunner);
  assert.match(errorOf(report) ?? '', new RegExp(`needs flow ${GRAPH_REPORT_SINCE.replaceAll('.', '\\.')}`), 'because an older flow has no such script, and the owner must hear which flow has it instead of a shell error');
});

test('GraphReport_ScriptFails_ErrorCarriesWhatTheScriptSaid', async () => {
  const failing: CommandRunner = async () => ({ code: 2, stdout: '', stderr: 'flow: no .flow in /somewhere\n', timedOut: false });
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, null, failing);
  assert.match(errorOf(report) ?? '', /no \.flow in \/somewhere/, 'because the page shows the script\'s own reason');
});

test('GraphReport_ScriptPrintsNothingToStderr_ErrorCarriesItsExitCode', async () => {
  const silent: CommandRunner = async () => ({ code: 3, stdout: '', stderr: '', timedOut: false });
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, null, silent);
  assert.match(errorOf(report) ?? '', /exit 3/, 'because a failure with no words still needs something the owner can search for');
});

test('GraphReport_ScriptRunsTooLong_ErrorSaysSo', async () => {
  const stuck: CommandRunner = async () => ({ code: null, stdout: '', stderr: '', timedOut: true });
  const report = await readGraphReport(FIXTURE_ROOT, FAKE_PLUGIN, null, stuck);
  assert.match(errorOf(report) ?? '', /ran too long/, 'because a killed script has no exit code and no words of its own');
});
