import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { parseRoute } from '../src/route.ts';
import { GraphReport } from '../src/screens/GraphReport.tsx';
import { HTTP_OK } from '../src/useProject.ts';
import type { ApiResponse } from '../src/api.ts';
import { FakeDaemon, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const REPORT_PATH = '/api/projects/project/graph-report';
const HTTP_NOT_FOUND = 404;

/** A report as the flow script prints it: one row per step, the header row first. */
function reportWith(step: string, median: string): string {
  return [
    '# Flow graph report',
    '',
    '## Steps',
    '',
    '| step | runs | median | nine in ten within | failed | cost | runs per item |',
    '|---|---|---|---|---|---|---|',
    `| ${step} | 4 | ${median} | 31m 02s | 1 | $2.50 | 2.0 |`,
    '',
  ].join('\n');
}

/** A daemon whose report script is still running: it never answers, and keeps the signal of the screen that asked. */
class DaemonWithASlowReport extends FakeDaemon {
  asking: AbortSignal | null = null;

  override get(_path: string, signal: AbortSignal): Promise<ApiResponse> {
    this.asking = signal;
    return new Promise(() => {});
  }
}

async function renderReport(daemon: FakeDaemon): Promise<void> {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><GraphReport snapshot={snapshotAt(TAKEN_AT, 0)} /></Wrapper>);
  await act(async () => {});
}

/** The cells of the report's first step row, as the page shows them. */
function firstStepRow(): string[] {
  const [, row] = within(screen.getByRole('table')).getAllByRole('row');
  return within(row!).getAllByRole('cell').map((cell) => cell.textContent ?? '');
}

test('GraphReport_DaemonHasAReport_ShowsEachStepAsATableRow', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', '20m 24s') } }));
  await renderReport(daemon);
  expect(firstStepRow(), 'because the owner reads a step\'s runs, times, failures and cost side by side').toEqual(['verify', '4', '20m 24s', '31m 02s', '1', '$2.50', '2.0']);
});

test('GraphReport_DaemonHasAReport_SaysWhichDaysItCovers', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', '20m 24s') } }));
  await renderReport(daemon);
  expect(screen.getByText(/the last 7 days against the 7 before/), 'because "slower" means nothing without the two periods compared').toBeTruthy();
});

test('GraphReport_HowToReadThis_ExplainsEveryNumberColumnOfTheStepsTable', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', '20m 24s') } }));
  await renderReport(daemon);
  const [headerRow] = within(screen.getByRole('table')).getAllByRole('row');
  const numberColumns = within(headerRow!).getAllByRole('columnheader').map((cell) => cell.textContent ?? '').filter((name) => name !== 'step');
  const legend = screen.getByText('How to read this').closest('details')!;
  const explained = numberColumns.filter((name) => within(legend).queryByText(name, { selector: 'strong' }) !== null);
  expect(explained, 'because a column nobody explains is a number the owner cannot use').toEqual(numberColumns);
});

test('GraphReport_DaemonSendsDailyLines_DrawsAChartForTheStep', async () => {
  const daemon = new FakeDaemon();
  const daily = [{ day: '2026-10-23', step: 'verify', runs: 2, seconds: 600, median: 300, within: 300, failed: 0, cost: 0.2, items: 1 }];
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', '20m 24s'), daily } }));
  await renderReport(daemon);
  expect(screen.getByRole('region', { name: 'verify: typical run time by day' }), 'because the days the flow kept are what shows a step getting slower').toBeTruthy();
});

test('GraphReport_FlowWithNoDailyLines_ShowsTheReportWithNoChart', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', '20m 24s') } }));
  await renderReport(daemon);
  expect([screen.queryByRole('region', { name: 'Steps over time' }), firstStepRow()[0]], 'because an older flow keeps no history, and its report must still show').toEqual([null, 'verify']);
});

test('GraphReport_DaemonCannotReadIt_SaysWhy', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_NOT_FOUND, body: { error: 'the installed flow has no graph report: it needs flow 1.44.0 or later' } }));
  await renderReport(daemon);
  expect(screen.getByText(/it needs flow 1\.44\.0 or later/), 'because an owner on an older flow must hear what to update, not see an empty page').toBeTruthy();
});

test('GraphReport_ReadAgain_ShowsTheNewReport', async () => {
  const daemon = new FakeDaemon();
  const medians = ['20m 24s', '4m 10s'];
  daemon.answer('GET', REPORT_PATH, () => ({ status: HTTP_OK, body: { days: 7, markdown: reportWith('verify', medians.shift() ?? '') } }));
  await renderReport(daemon);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Read again' })); });
  expect(firstStepRow()[2], 'because the report is read when asked and the runs since the page opened must show').toBe('4m 10s');
});

test('GraphReport_ScreenClosesWhileTheReportIsRead_CancelsItsRequest', async () => {
  const daemon = new DaemonWithASlowReport();
  const Wrapper = daemon.screenWrapper();
  const { unmount } = render(<Wrapper><GraphReport snapshot={snapshotAt(TAKEN_AT, 0)} /></Wrapper>);
  await act(async () => {});
  unmount();
  expect(daemon.asking?.aborted, 'because the daemon ends the script only when the request behind it is cancelled').toBe(true);
});

test('GraphRoute_Parses_AsItsOwnScreen', () => {
  expect(parseRoute('#/foosbrawl/graph').screen, 'because the report has a page of its own that a link can name').toBe('graph');
});
