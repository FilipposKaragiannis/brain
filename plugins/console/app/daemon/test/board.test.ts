import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseBoard, readBoard, withConsoleTrackerErrors } from '../src/collectors/board.ts';
import type { CommandRunner } from '../src/collectors/exec.ts';

const JIRA_DOWN = { tracker: 'jira', code: 1, message: 'flow: jira.project is not set' };

test('ParseBoard_TrackerErrors_ReadAsReported', () => {
  const board = parseBoard(JSON.stringify({ items: [], tracker_errors: [JIRA_DOWN] }));
  assert.deepEqual(board.trackerErrors, [JIRA_DOWN], 'because board.sh names each tracker whose list failed, with its exit code and last stderr line');
});

test('ParseBoard_NoTrackerErrors_None', () => {
  assert.deepEqual(parseBoard(JSON.stringify({ items: [] })).trackerErrors, [], 'because a plugin before tracker_errors reports none, which is no failure');
});

test('ParseBoard_TrackerErrorWithoutATracker_LeftOut', () => {
  const board = parseBoard(JSON.stringify({ items: [], tracker_errors: [{ code: 1, message: 'x' }, 'jira', null] }));
  assert.deepEqual(board.trackerErrors, [], 'because an error the console cannot pin on a tracker would show against none');
});

test('ConsoleTrackerErrors_JiraWithoutTokenInTheConsole_NamesTheVariable', () => {
  const [error] = withConsoleTrackerErrors([], ['github', 'jira'], {});
  assert.equal(error?.tracker, 'jira', 'because the Jira items are the ones that go missing');
  assert.match(error?.message ?? '', /^JIRA_API_TOKEN is not set in the console's environment/, 'because the remedy is the variable, and the console is where it is missing');
});

test('ConsoleTrackerErrors_JiraWithoutToken_StandsInForTheAdaptersError', () => {
  const errors = withConsoleTrackerErrors([JIRA_DOWN], ['jira'], {});
  assert.deepEqual([errors.length, errors[0]?.code], [1, null], "because the adapter's error then only repeats the missing token, so the console's own, with its remedy, replaces it");
});

test('ConsoleTrackerErrors_TokenSet_ReportedErrorsKept', () => {
  assert.deepEqual(withConsoleTrackerErrors([JIRA_DOWN], ['jira'], { JIRA_API_TOKEN: 'set' }), [JIRA_DOWN], 'because with the token in place the adapter knows best why it failed');
});

test('ParseBoard_HoldKeys_KeptInTheState', () => {
  const item = { id: 'gh#9', kind: 'task', title: 'Nine', size: 'S', priority: 'P1', status: 'open', labels: [], blocked_by: [], open_children: 0, parent: '', url: '', state: { step: 'implement', gate: 'none', worktree: 'wt-3', pr: '', last_event: '', profile: '', attempts: 0, held_by: 'gh#12', held_reason: 'shares src/a.cs' } };
  const [parsed] = parseBoard(JSON.stringify({ items: [item] })).items;
  assert.deepEqual([parsed?.state.held_by, parsed?.state.held_reason], ['gh#12', 'shares src/a.cs'], 'because the console shows what a held item waits behind, and why');
});

test('ConsoleTrackerErrors_NoJiraTracker_NothingAdded', () => {
  assert.deepEqual(withConsoleTrackerErrors([], ['github', 'local'], {}), [], 'because a project off Jira needs no Jira token');
});

test('ReadBoard_JiraTrackerAndNoToken_ErrorReportedBesideTheItems', async () => {
  const saved = process.env.JIRA_API_TOKEN;
  delete process.env.JIRA_API_TOKEN;
  try {
    const runner: CommandRunner = async () => ({ code: 0, stdout: JSON.stringify({ items: [{ id: 'gh#1', status: 'open', blocked_by: [] }] }), stderr: '', timedOut: false });
    const board = await readBoard('/p', '/plugin', runner, ['github', 'jira']);
    assert.deepEqual([board.items.map((item) => item.id), board.trackerErrors.map((error) => error.tracker)], [['gh#1'], ['jira']], 'because the GitHub items still show while the Jira ones are named as missing');
  } finally {
    if (saved !== undefined) process.env.JIRA_API_TOKEN = saved;
  }
});
