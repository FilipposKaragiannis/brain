import path from 'node:path';
import { DEFAULT_PORT, LOCALHOST } from './config.ts';
import type { CommandOutcome, LaunchdDependencies } from './launchd.ts';
import { flagsOfPlist, install, LAUNCHD_LABEL, launchdEnvironment, pidOf, PORT_WAIT_MS, plistPath, uninstall } from './launchd.ts';
import type { PidRecord } from './pidFile.ts';
import { parsePidRecord, pidFilePath } from './pidFile.ts';
import type { ConfigPaths } from './settings.ts';
import { checkProjectList, readStoredSettings, saveSettings } from './settings.ts';

const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_USAGE = 2;
/** How long `stop` waits for a foreground daemon to end after SIGTERM before it says so. */
export const STOP_WAIT_MS = 5000;
const STOP_POLL_MS = 100;

/** Where the console is installed under a home: one folder per version and `current`, the link to the one in use. */
export function installRoot(consoleHome: string): string {
  return path.join(consoleHome, '.local', 'share', 'brain-console');
}

/**
 * The main.ts a launch agent should run: the `current` link's path when this main.ts is the one
 * that link leads to, so an update needs only a restart; this file itself in a checkout.
 */
export function daemonEntry(self: string, consoleHome: string, realpath: (file: string) => string | null): string {
  const linked = path.join(installRoot(consoleHome), 'current', 'daemon', 'src', 'main.ts');
  const resolved = realpath(linked);
  return resolved !== null && resolved === realpath(self) ? linked : self;
}

export type HttpAnswer = { status: number; body: unknown };

/** Everything the command touches outside the process, so a test never reaches launchd, a browser, the network or the owner's home. */
export type CliDependencies = {
  launchd: LaunchdDependencies;
  version: string;
  /** The state dir when neither `--state-dir` nor BRAIN_CONSOLE_STATE names one. */
  defaultStateDir: string;
  cwd: string;
  isAlive: (pid: number) => boolean;
  /** The command line of a running pid (`ps -o command= -p`), or null when none runs. */
  processCommand: (pid: number) => Promise<string | null>;
  kill: (pid: number, signal: 'SIGTERM') => void;
  sleep: (ms: number) => Promise<void>;
  /** A request to the running daemon with the token as a bearer header. */
  http: (url: string, method: 'GET' | 'PUT', token: string, body?: unknown) => Promise<HttpAnswer>;
  /** Opens the page in the default browser (`open <url>`); the exit code. */
  openUrl: (url: string) => Promise<number>;
  /** Shows the end of the log, and follows it with `follow`, until it ends (`tail`); the exit code. */
  tail: (file: string, follow: boolean) => Promise<number>;
  /** Runs a shell script with arguments, its output to this terminal; the exit code. */
  runScript: (file: string, args: string[]) => Promise<number>;
  /** The daemon in this process (`start`): resolves only if it could not start. */
  startDaemon: (argv: string[]) => Promise<number>;
  /** The folders in a folder, by name; empty when it is missing. */
  listDirs: (folder: string) => string[];
  /** The install tree: where a link points (null when it is not one), relinking it in one step, removing a folder. */
  tree: { readLink(file: string): string | null; link(target: string, file: string): void; remove(folder: string): void };
};

/** The one line per subcommand that `help` prints. */
export const HELP = `brain-console: the Brain Console daemon and its page
  start [flags]       run the daemon here, in the foreground (--project <root>, --port <n>, --state-dir <d>, --config <file>, --token <t>)
  stop                stop the launchd job when it is loaded, else the foreground daemon
  restart             restart the launchd job, or stop the foreground daemon and start it here again
  status              loaded or not, pid, port, the URL without the token, config file, state dir, version
  open                open the page, token included, in the default browser
  url                 print the URL with the token, for scripts
  add <path>          watch one more project (a folder with .flow/config.yaml); a running daemon picks it up at once
  remove <path>       stop watching a project
  logs [-f]           the launchd daemon's log in the state dir; -f follows it
  install [flags]     run the daemon on login under launchd (the flags of start, but no --token)
  uninstall           stop the launchd job and remove it
  update              install a newer console plugin from the Claude plugin cache, then restart
  version             print the version
  help                this list
stop, restart, status, open, url, add, remove and logs take --state-dir <d>, --config <file> and --port <n> to reach a daemon started with them.`;

const SUBCOMMANDS = ['start', 'stop', 'restart', 'status', 'open', 'url', 'add', 'remove', 'logs', 'install', 'uninstall', 'update', 'version', 'help'] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];
const isSubcommand = (word: string | undefined): word is Subcommand => (SUBCOMMANDS as readonly string[]).includes(word ?? '');

/** `--state-dir`, `--config` and `--port`, as `stop`, `status` and the others take them; anything else is left. */
type Locating = { stateDir: string | null; config: string | null; port: number | null };

function locatingFlags(argv: string[]): { flags: Locating; rest: string[]; error: string | null } {
  const flags: Locating = { stateDir: null, config: null, port: null };
  const rest: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index] ?? '';
    const value = argv[index + 1];
    if (['--state-dir', '--config', '--port'].includes(flag)) {
      if (value === undefined) return { flags, rest, error: `${flag} needs a value` };
      if (flag === '--state-dir') flags.stateDir = value;
      if (flag === '--config') flags.config = value;
      if (flag === '--port') {
        const port = Number(value);
        if (!Number.isInteger(port) || port <= 0) return { flags, rest, error: `bad port: ${value}` };
        flags.port = port;
      }
      index += 1;
      continue;
    }
    rest.push(flag);
  }
  return { flags, rest, error: null };
}

/** The same flags read out of a start command line (a plist's or a pid file's), the rest ignored. */
function locatingOfStartFlags(argv: string[]): Locating {
  const pick = (name: string): string | null => {
    const index = argv.lastIndexOf(name);
    return index >= 0 ? (argv[index + 1] ?? null) : null;
  };
  const port = pick('--port');
  return { stateDir: pick('--state-dir'), config: pick('--config'), port: port === null ? null : Number(port) };
}

/** What the commands know about the daemon: how it runs (if it does), and where its files are. */
type Target = {
  mode: 'launchd' | 'foreground' | 'stopped';
  pid: number | null;
  /** launchd has the job, whether or not it runs now. */
  loaded: boolean;
  plistWritten: boolean;
  port: number;
  stateDir: string;
  paths: ConfigPaths;
  token: string | null;
  record: PidRecord | null;
  /** The launch agent on disk names its projects with --project, so the config file's do not count for it. */
  agentProjects: boolean;
};

/**
 * Whether a pid file's record is a daemon that still runs: its pid is alive and either holds the
 * record's port or runs main.ts. A pid reused after a crash is neither, so it is never signalled.
 */
async function ownsRecord(record: PidRecord, deps: CliDependencies): Promise<boolean> {
  if (!deps.isAlive(record.pid)) return false;
  const holder = await deps.launchd.portHolder(record.port);
  if (holder !== null && new RegExp(`^pid ${record.pid}\\b`).test(holder)) return true;
  return (await deps.processCommand(record.pid))?.includes('main.ts') === true;
}

/** The running daemon of the pid file in a state dir, or null; a stale file (dead or reused pid) is removed. */
async function liveRecord(stateDir: string, deps: CliDependencies): Promise<PidRecord | null> {
  const file = pidFilePath(stateDir);
  if (!deps.launchd.files.exists(file)) return null;
  const record = parsePidRecord(deps.launchd.files.read(file));
  if (record !== null && await ownsRecord(record, deps)) return record;
  deps.launchd.files.remove(file);
  return null;
}

function configPathsFor(file: string | null, fallback: ConfigPaths, cwd: string): ConfigPaths {
  if (file === null) return fallback;
  const resolved = path.resolve(cwd, file);
  return { configFile: resolved, legacyProjectsFile: path.join(path.dirname(resolved), 'projects.json') };
}

/**
 * Finds the daemon: the launchd job when it is loaded, else the foreground daemon of the pid file
 * in the state dir, else none. The launch agent's flags (unless the command named a state dir or
 * a config) say where a loaded job's files are, and where a stopped one's would be.
 */
async function locate(deps: CliDependencies, given: Locating): Promise<Target> {
  const { launchd } = deps;
  const printed = await launchd.launchctl(['print', `gui/${launchd.uid}/${LAUNCHD_LABEL}`]);
  const loaded = printed.code === 0;
  const plist = plistPath(launchd.home);
  const plistWritten = launchd.files.exists(plist);
  const none: Locating = { stateDir: null, config: null, port: null };
  const env = loaded ? { ...launchd.env, ...launchdEnvironment(launchd.env) } : launchd.env;
  const agentFlags = plistWritten ? flagsOfPlist(launchd.files.read(plist)) : [];
  const agent = given.stateDir === null && given.config === null ? locatingOfStartFlags(agentFlags) : none;
  const stateDirOf = (named: string | null): string => path.resolve(deps.cwd, given.stateDir ?? named ?? env['BRAIN_CONSOLE_STATE'] ?? deps.defaultStateDir);
  const searched = stateDirOf(loaded ? agent.stateDir : null);
  const running = loaded ? null : await liveRecord(searched, deps);
  const fromRecord = running === null ? none : { ...locatingOfStartFlags(running.argv), config: running.config, port: running.port };
  const fromPlist = running === null ? agent : none;
  const stateDir = running === null ? stateDirOf(agent.stateDir) : searched;
  const paths = configPathsFor(given.config ?? fromPlist.config ?? fromRecord.config, launchd.configPaths, deps.cwd);
  const stored = readStoredSettings(paths);
  const port = given.port ?? fromRecord.port ?? fromPlist.port ?? (stored.ok ? stored.value.file.port : undefined) ?? DEFAULT_PORT;
  const tokenFile = path.join(stateDir, 'token');
  const token = launchd.env['BRAIN_CONSOLE_TOKEN'] ?? (launchd.files.exists(tokenFile) ? launchd.files.read(tokenFile).trim() || null : null);
  const mode = loaded ? 'launchd' : running !== null ? 'foreground' : 'stopped';
  return { mode, pid: loaded ? numberOrNull(pidOf(printed.stdout)) : running?.pid ?? null, loaded, plistWritten, port, stateDir, paths, token, record: running, agentProjects: agentFlags.includes('--project') };
}

function numberOrNull(text: string | null): number | null {
  return text === null ? null : Number(text);
}

function pageUrl(target: Target, withToken: boolean): string {
  const base = `http://${LOCALHOST}:${target.port}/`;
  return withToken && target.token !== null ? `${base}?token=${target.token}` : base;
}

/** `brain-console <subcommand> [args]`: the exit code. No subcommand prints the help. */
export async function runCli(argv: string[], deps: CliDependencies): Promise<number> {
  const [word, ...args] = argv;
  const print = deps.launchd.print;
  if (word === undefined || word === 'help' || word === '--help' || word === '-h') { print(HELP); return EXIT_OK; }
  if (!isSubcommand(word)) { print(`brain-console: unknown command ${word}\n${HELP}`); return EXIT_USAGE; }
  if (word === 'version') { print(deps.version); return EXIT_OK; }
  if (word === 'install') return install(args, deps.launchd);
  if (word === 'uninstall') return uninstall(deps.launchd);
  if (word === 'start') return start(args, deps);
  if (word === 'update') return update(args, deps);
  const parsed = locatingFlags(args);
  if (parsed.error !== null) { print(`brain-console: ${parsed.error}`); return EXIT_USAGE; }
  const { flags, rest } = parsed;
  const takesPath = word === 'add' || word === 'remove';
  const takesFollow = word === 'logs';
  const expected = takesPath ? 1 : 0;
  const operands = takesFollow ? rest.filter((arg) => arg !== '-f' && arg !== '--follow') : rest;
  if (operands.length !== expected) {
    print(takesPath ? `brain-console: ${word} takes one folder: brain-console ${word} <path>` : `brain-console: ${word} takes no ${operands[0] ?? ''}`);
    return EXIT_USAGE;
  }
  const target = await locate(deps, flags);
  switch (word) {
    case 'status': return status(target, deps);
    case 'stop': return stop(target, deps);
    case 'restart': return restart(target, args, deps);
    case 'url': return url(target, deps);
    case 'open': return open(target, deps);
    case 'logs': return logs(target, rest.length !== operands.length, deps);
    case 'add': case 'remove': return changeProjects(word, operands[0] ?? '', target, deps);
  }
  return EXIT_USAGE;
}

async function start(args: string[], deps: CliDependencies): Promise<number> {
  const stateDir = path.resolve(deps.cwd, locatingOfStartFlags(args).stateDir ?? deps.launchd.env['BRAIN_CONSOLE_STATE'] ?? deps.defaultStateDir);
  const record = await liveRecord(stateDir, deps);
  if (record !== null) {
    deps.launchd.print(`brain-console: already running in the foreground, pid ${record.pid} on port ${record.port}; brain-console stop ends it`);
    return EXIT_FAILED;
  }
  return deps.startDaemon(args);
}

function status(target: Target, deps: CliDependencies): number {
  const print = deps.launchd.print;
  const plist = plistPath(deps.launchd.home);
  const running = target.mode === 'launchd'
    ? `loaded under launchd as ${LAUNCHD_LABEL}, ${target.pid === null ? 'not running now' : `pid ${target.pid}`}`
    : target.mode === 'foreground'
      ? `running in the foreground, pid ${target.pid ?? '?'} (not under launchd${target.plistWritten ? '' : '; brain-console install runs it on login'})`
      : `not running${target.plistWritten ? ` (${plist} is there: brain-console restart loads it)` : ' (brain-console start, or brain-console install to run it on login)'}`;
  print(`brain-console ${deps.version}`);
  print(`daemon: ${running}`);
  print(`port: ${target.port}`);
  print(`url: ${pageUrl(target, false)} (brain-console open adds the token)`);
  print(`config: ${target.paths.configFile}`);
  print(`state: ${target.stateDir}`);
  return target.mode === 'stopped' || target.pid === null ? EXIT_FAILED : EXIT_OK;
}

async function waitForExit(pid: number, deps: CliDependencies): Promise<boolean> {
  for (let waited = 0; waited < STOP_WAIT_MS; waited += STOP_POLL_MS) {
    if (!deps.isAlive(pid)) return true;
    await deps.sleep(STOP_POLL_MS);
  }
  return !deps.isAlive(pid);
}

async function stop(target: Target, deps: CliDependencies): Promise<number> {
  const { launchd } = deps;
  if (target.mode === 'launchd') {
    const bootout = await launchd.launchctl(['bootout', `gui/${launchd.uid}/${LAUNCHD_LABEL}`]);
    if (bootout.code !== 0) { launchd.print(`brain-console: launchctl could not stop ${LAUNCHD_LABEL}: ${bootout.stderr.trim()}`); return EXIT_FAILED; }
    launchd.print(`stopped ${LAUNCHD_LABEL}; it starts again on login, or now with brain-console restart`);
    return EXIT_OK;
  }
  if (target.mode === 'foreground' && target.pid !== null) {
    deps.kill(target.pid, 'SIGTERM');
    if (!(await waitForExit(target.pid, deps))) { launchd.print(`brain-console: pid ${target.pid} is still running ${STOP_WAIT_MS / 1000}s after SIGTERM`); return EXIT_FAILED; }
    const pidFile = pidFilePath(target.stateDir);
    if (launchd.files.exists(pidFile) && parsePidRecord(launchd.files.read(pidFile))?.pid === target.pid) launchd.files.remove(pidFile);
    launchd.print(`stopped the foreground daemon, pid ${target.pid}`);
    return EXIT_OK;
  }
  launchd.print('brain-console: not running');
  return EXIT_OK;
}

/** Waits for the port, then names the job's pid, as `install` does. */
async function reportLaunchd(target: Target, deps: CliDependencies): Promise<number> {
  const { launchd } = deps;
  if (!(await launchd.waitForPort(LOCALHOST, target.port, PORT_WAIT_MS))) {
    launchd.print(`brain-console: nothing listens on ${target.port} after ${PORT_WAIT_MS / 1000}s; see ${path.join(target.stateDir, 'daemon.log')}`);
    return EXIT_FAILED;
  }
  const pid = pidOf((await launchd.launchctl(['print', `gui/${launchd.uid}/${LAUNCHD_LABEL}`])).stdout);
  launchd.print(`restarted ${LAUNCHD_LABEL}${pid === null ? '' : `, pid ${pid}`}, on ${pageUrl(target, false)}`);
  return EXIT_OK;
}

async function restart(target: Target, args: string[], deps: CliDependencies): Promise<number> {
  const { launchd } = deps;
  const domain = `gui/${launchd.uid}`;
  if (target.mode === 'launchd') {
    const kicked = await launchd.launchctl(['kickstart', '-k', `${domain}/${LAUNCHD_LABEL}`]);
    if (kicked.code !== 0) { launchd.print(`brain-console: launchctl could not restart ${LAUNCHD_LABEL}: ${kicked.stderr.trim()}`); return EXIT_FAILED; }
    return reportLaunchd(target, deps);
  }
  if (target.mode === 'foreground' && target.record !== null) {
    const again = target.record.argv;
    const stopped = await stop(target, deps);
    if (stopped !== EXIT_OK) return stopped;
    return deps.startDaemon(again);
  }
  const plist = plistPath(launchd.home);
  if (target.plistWritten) {
    const loaded: CommandOutcome = await launchd.launchctl(['bootstrap', domain, plist]);
    if (loaded.code !== 0 && (await launchd.launchctl(['load', '-w', plist])).code !== 0) {
      launchd.print(`brain-console: launchctl could not load ${plist}: ${loaded.stderr.trim()}`);
      return EXIT_FAILED;
    }
    return reportLaunchd(await locate(deps, locatingFlags(args).flags), deps);
  }
  return start(args, deps);
}

function url(target: Target, deps: CliDependencies): number {
  if (target.mode === 'stopped') { deps.launchd.print('brain-console: not running; brain-console start runs it here, brain-console install on login'); return EXIT_FAILED; }
  if (target.token === null) { deps.launchd.print(`brain-console: no token in ${target.stateDir} yet; the daemon makes it on its first start`); return EXIT_FAILED; }
  deps.launchd.print(pageUrl(target, true));
  return EXIT_OK;
}

async function open(target: Target, deps: CliDependencies): Promise<number> {
  if (target.mode === 'stopped') { deps.launchd.print('brain-console: not running; brain-console start runs it here, brain-console install on login'); return EXIT_FAILED; }
  if (target.token === null) return url(target, deps);

  const code = await deps.openUrl(pageUrl(target, true));
  if (code !== 0) deps.launchd.print('brain-console: could not open the browser; brain-console url prints the address');
  return code === 0 ? EXIT_OK : EXIT_FAILED;
}

async function logs(target: Target, follow: boolean, deps: CliDependencies): Promise<number> {
  const file = path.join(target.stateDir, 'daemon.log');
  if (!deps.launchd.files.exists(file)) {
    deps.launchd.print(`brain-console: no log at ${file}; a daemon started with brain-console start logs to its own terminal`);
    return EXIT_FAILED;
  }
  return deps.tail(file, follow);
}

/** A root as typed: `~/` is the home folder, a relative one is from here. */
function rootOf(typed: string, deps: CliDependencies): string {
  const home = deps.launchd.home;
  const expanded = typed === '~' ? home : typed.startsWith('~/') ? path.join(home, typed.slice(2)) : typed;
  return path.resolve(deps.cwd, expanded).replace(/\/+$/, '') || '/';
}

function nextRoots(word: 'add' | 'remove', roots: string[], root: string): { roots: string[]; note: string | null; error: string | null } {
  const listed = roots.includes(root);
  if (word === 'add') return listed ? { roots, note: `${root} is already watched`, error: null } : { roots: [...roots, root], note: null, error: null };
  return listed ? { roots: roots.filter((entry) => entry !== root), note: null, error: null } : { roots, note: null, error: `${root} is not watched` };
}

/**
 * `add` and `remove`: through the running daemon's settings route when it runs (checked and
 * applied at once, no restart), else straight into the config file with the same checks.
 */
async function changeProjects(word: 'add' | 'remove', typed: string, target: Target, deps: CliDependencies): Promise<number> {
  const print = deps.launchd.print;
  const root = rootOf(typed, deps);
  if (target.mode !== 'stopped' && target.pid !== null && target.token !== null) {
    const settingsUrl = `http://${LOCALHOST}:${target.port}/api/settings`;
    let current: HttpAnswer;
    try { current = await deps.http(settingsUrl, 'GET', target.token); } catch (error) {
      print(`brain-console: the daemon on ${target.port} did not answer: ${error instanceof Error ? error.message : String(error)}`);
      return EXIT_FAILED;
    }
    const projects = (current.body as { projects?: { roots?: string[]; editable?: boolean; note?: string | null } } | null)?.projects;
    if (current.status !== 200 || projects === undefined) { print(`brain-console: the daemon answered ${current.status} for its settings`); return EXIT_FAILED; }
    if (projects.editable !== true) { print(`brain-console: the running daemon's projects cannot change: ${projects.note ?? ''}`); return EXIT_USAGE; }
    const next = nextRoots(word, projects.roots ?? [], root);
    if (next.error !== null) { print(`brain-console: ${next.error}`); return EXIT_FAILED; }
    if (next.note !== null) { print(next.note); return EXIT_OK; }
    const saved = await deps.http(settingsUrl, 'PUT', target.token, { projects: next.roots.map((entry) => ({ root: entry })) });
    if (saved.status !== 200) { print(`brain-console: ${(saved.body as { error?: string } | null)?.error ?? `the daemon answered ${saved.status}`}`); return EXIT_USAGE; }
    print(`${word === 'add' ? 'watching' : 'stopped watching'} ${root}; the running daemon picked it up (${next.roots.length} project${next.roots.length === 1 ? '' : 's'})`);
    return EXIT_OK;
  }
  if (target.agentProjects) {
    print("brain-console: projects come from the launch agent's --project flags; run brain-console install --project … to change them");
    return EXIT_USAGE;
  }
  const stored = readStoredSettings(target.paths);
  if (!stored.ok) { print(`brain-console: ${stored.error}`); return EXIT_USAGE; }
  const next = nextRoots(word, (stored.value.file.projects ?? []).map((entry) => entry.root), root);
  if (next.error !== null) { print(`brain-console: ${next.error}`); return EXIT_FAILED; }
  if (next.note !== null) { print(next.note); return EXIT_OK; }
  const checked = checkProjectList(next.roots);
  if (!checked.ok) { print(`brain-console: ${checked.error}`); return EXIT_USAGE; }
  const saved = saveSettings(target.paths, { projects: checked.value.map((project) => ({ root: project.root })) });
  if (!saved.ok) { print(`brain-console: ${saved.error}`); return EXIT_FAILED; }
  print(`${word === 'add' ? 'watching' : 'stopped watching'} ${root} in ${target.paths.configFile}; the daemon reads it when it starts`);
  return EXIT_OK;
}

/** Compares dotted versions number by number: 0.10.0 is newer than 0.9.2. */
export function compareVersions(left: string, right: string): number {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

/** The plugin caches `update` looks in, first to last: Claude's (CLAUDE_CONFIG_DIR, else ~/.claude), then Codex's. */
export function pluginCaches(home: string, env: NodeJS.ProcessEnv): string[] {
  const claude = env['CLAUDE_CONFIG_DIR'] ?? path.join(home, '.claude');
  return [path.join(claude, 'plugins', 'cache'), path.join(home, '.codex', 'plugins', 'cache')];
}

/** The newest console plugin in the first cache that has one with an install script, or null. */
export function newestCachedPlugin(home: string, deps: Pick<CliDependencies, 'listDirs' | 'launchd'>): { dir: string; version: string } | null {
  for (const cache of pluginCaches(home, deps.launchd.env)) {
    const found = deps.listDirs(cache).flatMap((marketplace) => deps.listDirs(path.join(cache, marketplace, 'console')).map((version) => ({ version, dir: path.join(cache, marketplace, 'console', version) })))
      .filter((entry) => /^\d+(\.\d+)*$/.test(entry.version) && deps.launchd.files.exists(path.join(entry.dir, 'scripts', 'install.sh')))
      .sort((left, right) => compareVersions(left.version, right.version));
    const newest = found.at(-1);
    if (newest !== undefined) return newest;
  }
  return null;
}

/** The versions under the install root other than the one kept and the current link, removed. */
function pruneVersions(root: string, keep: string, deps: CliDependencies): void {
  for (const name of deps.listDirs(root)) {
    if (name === keep || name === 'current') continue;
    deps.tree.remove(path.join(root, name));
    deps.launchd.print(`brain-console: removed ${name}`);
  }
}

/** Kickstarts the job and resolves to its new pid once that pid holds the port; null when it does not in time. */
async function restartConfirmed(target: Target, deps: CliDependencies): Promise<number | null> {
  const { launchd } = deps;
  const job = `gui/${launchd.uid}/${LAUNCHD_LABEL}`;
  if ((await launchd.launchctl(['kickstart', '-k', job])).code !== 0) return null;
  if (!(await launchd.waitForPort(LOCALHOST, target.port, PORT_WAIT_MS))) return null;
  const pid = pidOf((await launchd.launchctl(['print', job])).stdout);
  const holder = await launchd.portHolder(target.port);
  return pid !== null && holder !== null && new RegExp(`^pid ${pid}\\b`).test(holder) ? Number(pid) : null;
}

/**
 * `update`: when the cache has a newer console than this one, runs its install script without
 * touching launchd and without removing the old versions (the agent runs the `current` link).
 * A loaded job is then restarted; the old versions go only once the new pid holds the port, and
 * a restart that fails points `current` back at the version before and restarts that. With no
 * job loaded the old versions go at once, unless a foreground daemon still runs from one.
 */
async function update(args: string[], deps: CliDependencies): Promise<number> {
  const print = deps.launchd.print;
  if (args.length > 0) { print(`brain-console: update takes no ${args[0]}`); return EXIT_USAGE; }
  const caches = pluginCaches(deps.launchd.home, deps.launchd.env);
  const plugin = newestCachedPlugin(deps.launchd.home, deps);
  if (plugin === null) { print(`brain-console: no console plugin in ${caches.join(' or ')}; run: claude plugin install console@brain-plugins`); return EXIT_FAILED; }
  if (compareVersions(plugin.version, deps.version) <= 0) { print(`brain-console: already up to date (${deps.version}; the newest in the cache is ${plugin.version})`); return EXIT_OK; }
  const root = installRoot(deps.launchd.env['BRAIN_CONSOLE_HOME'] ?? deps.launchd.home);
  const current = path.join(root, 'current');
  const previous = deps.tree.readLink(current);
  print(`brain-console: updating ${deps.version} to ${plugin.version} from ${plugin.dir}`);
  const installed = await deps.runScript(path.join(plugin.dir, 'scripts', 'install.sh'), ['--no-launchd', '--keep-old']);
  if (installed !== EXIT_OK) return installed;
  const target = await locate(deps, { stateDir: null, config: null, port: null });
  if (target.mode === 'foreground') {
    print(`brain-console: the foreground daemon, pid ${target.pid ?? '?'}, still runs ${deps.version}; brain-console restart starts ${plugin.version}, and the next update removes the old version`);
    return EXIT_OK;
  }
  if (target.mode === 'launchd') {
    const pid = await restartConfirmed(target, deps);
    if (pid === null) {
      if (previous !== null && previous !== plugin.version) {
        deps.tree.link(previous, current);
        print(`brain-console: ${plugin.version} did not come up on port ${target.port}; current points back at ${previous}; see ${path.join(target.stateDir, 'daemon.log')}`);
        await restartConfirmed(target, deps);
      } else {
        print(`brain-console: ${plugin.version} did not come up on port ${target.port}; see ${path.join(target.stateDir, 'daemon.log')}`);
      }
      return EXIT_FAILED;
    }
    print(`restarted ${LAUNCHD_LABEL} on ${plugin.version}, pid ${pid}, on ${pageUrl(target, false)}`);
  }
  pruneVersions(root, plugin.version, deps);
  return EXIT_OK;
}
