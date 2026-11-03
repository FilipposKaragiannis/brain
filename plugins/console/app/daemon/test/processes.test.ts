import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { hostOf, kindOf, parseElapsed, parseProcessList, parseWorkingDirectories, readProcesses } from '../src/collectors/processes.ts';
import { PROCESS_COMMAND_CHARS } from '../src/snapshot.ts';

const NOW = new Date('2026-11-03T13:21:22Z');

test('Elapsed_DaysHoursMinutesSeconds', () => {
  assert.equal(parseElapsed('01-02:03:04'), 93784, 'because 1 day, 2 hours, 3 minutes and 4 seconds is 93784 seconds');
  assert.equal(parseElapsed('15:42'), 942, 'because a short etime is minutes and seconds');
});

test('HostOf_AgentsOnly', () => {
  assert.equal(hostOf('/Users/x/.local/bin/claude --session-id abc'), 'claude', 'because a claude session is an agent');
  assert.equal(hostOf('/opt/codex exec --cd here'), 'codex', 'because codex exec is how the flow starts a Codex agent');
  assert.equal(hostOf('/Users/x/.local/bin/claude daemon run --origin transient'), null, 'because the host daemon works in no worktree');
  assert.equal(hostOf('/opt/codex app-server --listen unix://'), null, 'because the app server is not an agent');
  assert.equal(hostOf('/usr/bin/python3 claude.py'), null, 'because only the executable name counts');
});

test('KindOf_UnattendedIsAgentInteractiveIsSession', () => {
  assert.equal(kindOf('claude', '/x/claude -p /flow:next gh#9 --permission-mode auto'), 'agent', 'because host.sh starts Claude runs with -p');
  assert.equal(kindOf('claude', '/x/claude --session-id abc --permission-mode auto'), 'session', 'because an interactive session has no -p');
  assert.equal(kindOf('codex', '/x/codex exec -C /w -s workspace-write'), 'agent', 'because host.sh starts Codex runs with exec');
  assert.equal(kindOf('codex', '/x/codex --cd /w'), 'session', 'because a plain codex is the owner typing');
});

test('ProcessList_PidElapsedCommand', () => {
  const rows = parseProcessList('  100   15:42 /usr/local/bin/claude --x\n  7 01-00:00:01 /bin/sh');
  assert.deepEqual(rows.map((row) => [row.pid, row.elapsedSeconds]), [[100, 942], [7, 86401]], 'because ps prints pid, etime and the command');
});

test('WorkingDirectories_PairPidWithPath', () => {
  const directories = parseWorkingDirectories('p100\nfcwd\nn/work/a\np200\nfcwd\nn/work/b\n');
  assert.equal(directories.get(200), '/work/b', 'because lsof -F groups the n line under its p line');
});

const CODEX_RELEASE = '/Users/x/.codex/packages/app-server-daemon/releases/0.164.0-aarch64-apple-darwin/bin/codex';

test('HostOf_CodexDesktopAppServer_Never', () => {
  assert.equal(hostOf(`${CODEX_RELEASE} app-server --listen unix:// -c features.api_key_model_discovery=false`), null, 'because the Codex desktop app\'s server is not a person typing in the folder');
});

test('HostOf_CodexDesktopPidLoop_Never', () => {
  assert.equal(hostOf(`${CODEX_RELEASE} app-server daemon pid-update-loop`), null, 'because the app server\'s pid loop is not a session either');
});

test('HostOf_CodexServerAfterAConfigOption_Never', () => {
  assert.equal(hostOf('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled'), null, 'because a -c option before the subcommand does not hide that it is the app server');
});

test('HostOf_PromptMentionsTheDaemon_StillAnAgent', () => {
  assert.equal(hostOf('/usr/local/bin/claude -p fix the daemon restart and the app-server crash'), 'claude', 'because only the words right after the executable name a server; a prompt may say anything');
});

test('HostOf_ClaudeUnderAFolderWithSpaces_Claude', () => {
  const desktop = '/Users/x/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude --output-format stream-json --input-format stream-json';
  assert.equal(hostOf(desktop), 'claude', 'because the Claude desktop app keeps its CLI under Application Support, and that session is an app\'s');
});

for (const wrapper of ['sh /usr/local/bin/claude', 'disclaimer /usr/local/bin/claude', 'node /opt/homebrew/bin/claude', 'vim /Users/x/notes/claude']) {
  test(`HostOf_${wrapper.split(' ')[0]}WithAHostPathAsArgument_Never`, () => {
    assert.equal(hostOf(wrapper), null, `because in "${wrapper}" the program is ${wrapper.split(' ')[0]}, and a claude path is only its argument`);
  });
}

test('HostOf_WrapperBeforeTheHost_Never', () => {
  assert.equal(hostOf('/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /Users/x/claude --output-format stream-json'), null, 'because the wrapper is not the host, and the host itself has its own row');
});

test('ReadProcesses_LongCommand_TrimmedTo200', async () => {
  const runner: CommandRunner = async (request) => request.command === 'ps'
    ? { code: 0, stdout: `  100 00:10 /usr/local/bin/claude -p ${'x'.repeat(400)}\n`, stderr: '', timedOut: false }
    : { code: 0, stdout: 'p100\nfcwd\nn/w\n', stderr: '', timedOut: false };
  const { agents } = await readProcesses(runner, () => NOW);
  assert.equal(agents[0]?.command.length, PROCESS_COMMAND_CHARS, 'because a prompt can be pages long and the card needs the start of it');
});

/** A live implement run as seen on task 33: its owner loop (19487) and its claude worker (23465). */
const RUN_LISTING = [
  `19487 25:43 /bin/sh /Users/x/.claude/plugins/cache/brain-plugins/flow/1.31.0/scripts/run-unattended.sh next`,
  `23465 24:39 /Users/x/.local/bin/claude -p /flow:next local:task/33 --permission-mode auto`,
].join('\n');
const WORKER_CWD = 'p23465\nfcwd\nn/work/TophatContextService-wt-1\n';
const answered = (stdout: string): CommandResult => ({ code: 0, stdout, stderr: '', timedOut: false });
const TIMED_OUT: CommandResult = { code: null, stdout: '', stderr: '', timedOut: true };

/** A runner whose ps and lsof answer as given. */
const lookups = (ps: CommandResult, lsof: CommandResult): CommandRunner => async (request) => (request.command === 'ps' ? ps : lsof);

test('ReadProcesses_PsExitsNonZero_ListUnavailableNotEmpty', async () => {
  const { list } = await readProcesses(lookups({ code: 1, stdout: '', stderr: 'ps: Operation not permitted\n', timedOut: false }, answered(WORKER_CWD)), () => NOW);
  assert.deepEqual(list.status === 'unavailable' ? list.reason : list.status, 'ps exited 1: ps: Operation not permitted', 'because a failed ps knows nothing, and an empty list would say every run is dead');
});

test('ReadProcesses_PsTimesOut_ListUnavailableWithTheTimeout', async () => {
  const { list } = await readProcesses(lookups(TIMED_OUT, answered(WORKER_CWD)), () => NOW);
  assert.deepEqual(list.status === 'unavailable' ? [list.reason, list.lookup?.timedOut] : list.status, ['ps timed out after 10s', true], 'because a ps cut off by its timeout has no exit code and lists nothing, which is not "nothing runs"');
});

test('ReadProcesses_PsListsNothing_ListUnavailable', async () => {
  const { list } = await readProcesses(lookups(answered(''), answered(WORKER_CWD)), () => NOW);
  assert.equal(list.status, 'unavailable', 'because a machine always runs some process, so an empty listing is a failed read, as flow\'s _health.py procs says');
});

test('ReadProcesses_LsofTimesOut_ListPartialNamingTheWorker', async () => {
  const { list } = await readProcesses(lookups(answered(RUN_LISTING), TIMED_OUT), () => NOW);
  assert.deepEqual(list.status === 'partial' ? [list.reason, list.unplaced] : list.status, ['lsof timed out after 10s; no working directory for pid 23465', [23465]], 'because ps saw the worker, and only where it works is unknown');
});

test('ReadProcesses_LsofFails_ListPartial', async () => {
  const { list } = await readProcesses(lookups(answered(RUN_LISTING), { code: 1, stdout: '', stderr: 'lsof: no pwd entry\n', timedOut: false }), () => NOW);
  assert.equal(list.status === 'partial' ? list.reason : list.status, 'lsof exited 1: lsof: no pwd entry; no working directory for pid 23465', 'because the log and the page say which lookup failed and how');
});

test('ReadProcesses_LsofLeavesOutAPid_ListPartial', async () => {
  const { list } = await readProcesses(lookups(answered(RUN_LISTING), answered('')), () => NOW);
  assert.equal(list.status === 'partial' ? list.reason : list.status, 'lsof gave no working directory for pid 23465', 'because a pid ps listed is never dropped as if it did not run');
});

test('ReadProcesses_EveryHostPlaced_ListComplete', async () => {
  const { agents, list } = await readProcesses(lookups(answered(RUN_LISTING), answered(WORKER_CWD)), () => NOW);
  assert.deepEqual([list.status, agents.map((agent) => agent.cwd)], ['complete', ['/work/TophatContextService-wt-1']], 'because ps and lsof both answered for every claude, so a worktree with no agent truly has none');
});

test('ReadProcesses_UnattendedLoop_ListedAsAHostWithItsStart', async () => {
  const { hosts } = await readProcesses(lookups(answered(RUN_LISTING), TIMED_OUT), () => NOW);
  assert.deepEqual(hosts.find((host) => host.pid === 19487)?.startedAt, '2026-11-03T12:55:39.000Z', 'because the loop owns the run, and its start (25:43 before the read) tells it from a later process that reused the pid');
});
