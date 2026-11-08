import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { hostOf, kindOf, parseElapsed, parseProcessList, parseWorkingDirectories, readProcesses, readSession, serverOf } from '../src/collectors/processes.ts';
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
  assert.equal(hostOf('/x/claude -p mcp configuration is broken --permission-mode auto'), 'claude', 'because a prompt that starts with a server word is still an unattended run');
  assert.equal(hostOf('/opt/codex exec daemon crashes on startup'), 'codex', 'because codex exec runs an agent whatever its prompt says');
  assert.equal(hostOf('/x/claude --permission-mode auto daemon'), 'claude', 'because only the subcommand names a server, not a later word');
  assert.equal(serverOf('/x/claude -p mcp configuration is broken'), null, 'because an unattended run is never listed as a server');
  assert.equal(hostOf('/Users/x/.local/bin/claude mcp serve'), null, 'because Claude\'s MCP server serves another client from wherever it was started');
  assert.equal(hostOf('/usr/bin/python3 claude.py'), null, 'because only the executable name counts');
});

test('KindOf_UnattendedIsAgentInteractiveIsSession', () => {
  assert.equal(kindOf('claude', '/x/claude -p /flow:next gh#9 --permission-mode auto'), 'agent', 'because host.sh starts Claude runs with -p');
  assert.equal(kindOf('claude', '/x/claude --session-id abc --permission-mode auto'), 'session', 'because an interactive session has no -p');
  assert.equal(kindOf('codex', '/x/codex exec -C /w -s workspace-write'), 'agent', 'because host.sh starts Codex runs with exec');
  assert.equal(kindOf('codex', '/x/codex --cd /w'), 'session', 'because a plain codex is the owner typing');
});

test('ProcessList_PidPpidElapsedCommand', () => {
  const rows = parseProcessList('  100    99   15:42 /usr/local/bin/claude --x\n  7     1 01-00:00:01 /bin/sh');
  assert.deepEqual(rows.map((row) => [row.pid, row.ppid, row.elapsedSeconds]), [[100, 99, 942], [7, 1, 86401]], 'because ps prints pid, ppid, etime and the command');
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
    ? { code: 0, stdout: `  100    99 00:10 /usr/local/bin/claude -p ${'x'.repeat(400)}\n`, stderr: '', timedOut: false }
    : { code: 0, stdout: 'p100\nfcwd\nn/w\n', stderr: '', timedOut: false };
  const { agents } = await readProcesses(runner, () => NOW);
  assert.equal(agents[0]?.command.length, PROCESS_COMMAND_CHARS, 'because a prompt can be pages long and the card needs the start of it');
});

/** A live implement run as seen on task 33: its owner loop (19487) and its claude worker (23465). */
const RUN_LISTING = [
  `19487     1 25:43 /bin/sh /Users/x/.claude/plugins/cache/brain-plugins/flow/1.31.0/scripts/run-unattended.sh next`,
  `23465 19487 24:39 /Users/x/.local/bin/claude -p /flow:next local:task/33 --permission-mode auto`,
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

const SESSION_CWD = 'p62102\nfcwd\nn/work/projects/foosbrawl-wt-10\n';
/** The interactive claude that sat in foosbrawl-wt-10 for twelve days. */
const IDLE_SESSION = '62102 62090 12-16:46:34 /Users/x/.local/bin/claude --permission-mode auto';

test('ReadProcesses_Session_CarriesItsStartFromTheRead', async () => {
  const { agents } = await readProcesses(lookups(answered(IDLE_SESSION), answered(SESSION_CWD)), () => NOW);
  assert.equal(agents[0]?.startedAt, '2026-10-21T20:34:48.000Z', 'because a stop names the session by its start, 12 days 16:46:34 before the read, so a pid taken by a later process is told apart');
});

test('ReadSession_SameInteractiveSession_ItsStart', async () => {
  const found = await readSession(lookups(answered(IDLE_SESSION), answered('')), () => NOW, 62102);
  assert.deepEqual([found?.pid, found?.startedAt], [62102, '2026-10-21T20:34:48.000Z'], 'because the stop checks the pid still runs the session started then');
});

test('ReadSession_PidGone_Null', async () => {
  const found = await readSession(lookups({ code: 1, stdout: '', stderr: '', timedOut: false }, answered('')), () => NOW, 62102);
  assert.equal(found, null, 'because ps -p exits 1 for a pid that no longer runs, and there is nothing to stop');
});

test('ReadSession_PsTimesOut_Null', async () => {
  assert.equal(await readSession(lookups(TIMED_OUT, answered('')), () => NOW, 62102), null, 'because a pid ps could not read is never signalled');
});

for (const [name, what, row] of [
  ['UnattendedAgent', 'an unattended agent', '62102     1 00:30 /usr/local/bin/claude -p /flow:next gh#9 --permission-mode auto'],
  ['ClaudeDaemon', 'the claude daemon', '62102     1 00:30 /Users/x/.local/bin/claude daemon run --origin transient'],
  ['CodexAppServer', 'the Codex app server', `62102     1 00:30 ${CODEX_RELEASE} app-server --listen unix:///tmp/codex.sock`],
  ['AnotherProgram', 'another program', '62102     1 00:30 /usr/bin/vim notes.md'],
] as const) {
  test(`ReadSession_PidNowRuns${name}_Null`, async () => {
    assert.equal(await readSession(lookups(answered(row), answered('')), () => NOW, 62102), null, `because the pid now runs ${what}, which Stop session must never signal`);
  });
}

const CODEX_APP = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex';

for (const [name, command, label] of [
  ['CodexAppServer', `${CODEX_RELEASE} app-server --listen unix:///tmp/codex.sock`, 'Codex app server'],
  ['CodexPidLoop', `${CODEX_RELEASE} app-server daemon pid-update-loop`, 'Codex app server pid loop'],
  ['CodexExecServer', `${CODEX_APP} exec-server --listen stdio`, 'Codex exec server'],
  ['ClaudeDaemon', '/Users/x/.local/bin/claude daemon run --origin transient', 'Claude daemon'],
  ['ClaudeMcpServer', '/Users/x/.local/bin/claude mcp serve', 'Claude MCP server'],
] as const) {
  test(`ServerOf_${name}_NamedPlainly`, () => {
    assert.equal(serverOf(command)?.label, label, `because the owner reads "${label}", not the command, to know what runs`);
  });
}

test('ServerOf_AgentSessionOrOtherProgram_Null', () => {
  assert.deepEqual(
    [serverOf('/usr/local/bin/claude -p fix the daemon restart'), serverOf('/Users/x/.local/bin/claude --permission-mode auto'), serverOf('/usr/bin/vim daemon.md')],
    [null, null, null],
    'because agents and sessions are listed as such, and a program that is neither host serves nothing of theirs',
  );
});

/** pid 64347 and 56354 work in foosbrawl-wt-10; the app bundle's servers (701, 702) work in the home folder. */
const SERVER_LISTING = [
  `64347     1 2-03:00:00 ${CODEX_RELEASE} app-server --listen unix:///tmp/codex.sock`,
  `56354     1 2-03:00:01 ${CODEX_RELEASE} app-server daemon pid-update-loop`,
  `701     1 05:00 ${CODEX_APP} app-server --analytics-default-enabled`,
  IDLE_SESSION,
].join('\n');
const SERVER_CWDS = 'p64347\nfcwd\nn/work/projects/foosbrawl-wt-10\np56354\nfcwd\nn/work/projects/foosbrawl-wt-10\np701\nfcwd\nn/Users/x\n' + SESSION_CWD;

test('ReadProcesses_Servers_InTheSameLsofAsTheSessions', async () => {
  const asked: string[][] = [];
  const runner: CommandRunner = async (request) => {
    if (request.command === 'lsof') asked.push(request.args);
    return request.command === 'ps' ? answered(SERVER_LISTING) : answered(SERVER_CWDS);
  };
  await readProcesses(runner, () => NOW);
  assert.deepEqual(asked.map((args) => args.at(-1)), ['62102,64347,56354,701'], 'because one lsof call finds where the sessions and the servers work');
});

test('ReadProcesses_Servers_ListedApartFromTheAgents', async () => {
  const { agents, servers } = await readProcesses(lookups(answered(SERVER_LISTING), answered(SERVER_CWDS)), () => NOW);
  assert.deepEqual(
    [agents.map((agent) => agent.pid), servers.map((server) => [server.pid, server.label, server.cwd])],
    [[62102], [[64347, 'Codex app server', '/work/projects/foosbrawl-wt-10'], [56354, 'Codex app server pid loop', '/work/projects/foosbrawl-wt-10'], [701, 'Codex app server', '/Users/x']]],
    'because a server is never an agent or a session, yet the owner still sees what runs',
  );
});

test('ReadProcesses_Server_CarriesItsStartAndElapsed', async () => {
  const { servers } = await readProcesses(lookups(answered(SERVER_LISTING), answered(SERVER_CWDS)), () => NOW);
  const server = servers.find((entry) => entry.pid === 64347);
  assert.deepEqual([server?.elapsedSeconds, server?.startedAt], [183600, '2026-11-01T10:21:22.000Z'], 'because "running for" counts from the start ps gives, 2 days 3 hours before the read');
});

test('ReadProcesses_LsofMissesAServer_LeftOutAndListComplete', async () => {
  const { servers, list } = await readProcesses(lookups(answered(SERVER_LISTING), answered(SESSION_CWD)), () => NOW);
  assert.deepEqual([servers, list.status], [[], 'complete'], 'because a server is only shown, so one with no known folder is left out without marking the run picture incomplete');
});

test('ReadProcesses_OnlyServers_StillLooksUpWhereTheyWork', async () => {
  const { agents, servers } = await readProcesses(lookups(answered(SERVER_LISTING.split('\n').slice(0, 1).join('\n')), answered(SERVER_CWDS)), () => NOW);
  assert.deepEqual([agents, servers.map((server) => server.pid)], [[], [64347]], 'because a machine with no agent may still run a server in the project');
});

test('ReadProcesses_Agent_CarriesItsParentPid', async () => {
  const { agents } = await readProcesses(lookups(answered(RUN_LISTING), answered(WORKER_CWD)), () => NOW);
  assert.equal(agents[0]?.ppid, 19487, 'because the worker\'s parent is the loop that owns its run, and the agents page walks up to it');
});

/** How flow's host.sh starts a Codex run: from wherever the job runs, here the project root, with the worktree as `-C`. */
const CODEX_RUN = (cd: string): string => `31000 19487 02:00 /opt/homebrew/bin/codex exec --json ${cd} -s workspace-write --dangerously-bypass-hook-trust -c approval_policy="never" -m gpt-6-sol fix nine`;
const PROJECT_ROOT_CWD = 'p31000\nfcwd\nn/work/app\n';
const agentCwd = async (row: string): Promise<string | undefined> =>
  (await readProcesses(lookups(answered(row), answered(PROJECT_ROOT_CWD)), () => NOW)).agents[0]?.cwd;

test('ReadProcesses_CodexExecWithCdLaunchedFromTheRoot_WorksInTheCdDirectory', async () => {
  assert.equal(await agentCwd(CODEX_RUN('-C /work/app-wt-2')), '/work/app-wt-2', 'because codex exec -C keeps the cwd it was started in, and the run works in the worktree it names');
});

test('ReadProcesses_CodexExecWithLongCd_WorksInTheCdDirectory', async () => {
  assert.equal(await agentCwd(CODEX_RUN('--cd /work/app-wt-2')), '/work/app-wt-2', 'because --cd is the long spelling of -C');
});

test('ReadProcesses_CodexExecWithCdJoined_WorksInTheCdDirectory', async () => {
  assert.equal(await agentCwd(CODEX_RUN('--cd=/work/app-wt-2')), '/work/app-wt-2', 'because --cd=<dir> names the same directory as --cd <dir>');
});

test('ReadProcesses_CodexExecWithRelativeCd_ResolvedAgainstItsCwd', async () => {
  assert.equal(await agentCwd(CODEX_RUN('-C ../app-wt-2')), '/work/app-wt-2', 'because codex resolves a relative -C against the folder it was started in');
});

test('ReadProcesses_CodexExecWithoutCd_WorksInItsCwd', async () => {
  assert.equal(await agentCwd(CODEX_RUN('')), '/work/app', 'because a codex exec that names no directory works where it was started');
});

test('ReadProcesses_ClaudeWhosePromptSaysCd_WorksInItsCwd', async () => {
  const row = '31000 19487 02:00 /usr/local/bin/claude -p fix the -C /work/app-wt-2 option --permission-mode auto';
  assert.equal(await agentCwd(row), '/work/app', 'because claude has no -C option; the words are its prompt, and claude works where lsof says');
});
