import path from 'node:path';
import { readConfig } from './config.ts';
import type { ConfigPaths } from './settings.ts';

/** The launchd job that runs the daemon on login. */
export const LAUNCHD_LABEL = 'com.brain.console';
/** How long `install` waits for the daemon to listen before it gives up and points at the log. */
export const PORT_WAIT_MS = 15000;
const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_BAD_CONFIG = 2;

export type CommandOutcome = { code: number | null; stdout: string; stderr: string };

/** Everything `install`, `uninstall` and `status` touch outside the process, so a test never reaches launchd or the disk. */
export type LaunchdDependencies = {
  launchctl: (args: string[]) => Promise<CommandOutcome>;
  files: { write(file: string, text: string): void; remove(file: string): void; exists(file: string): boolean; read(file: string): string; mkdir(folder: string): void };
  /** Resolves true once something listens on the port, false when the wait ran out. */
  waitForPort: (host: string, port: number, timeoutMs: number) => Promise<boolean>;
  print: (line: string) => void;
  env: NodeJS.ProcessEnv;
  uid: number;
  home: string;
  /** The absolute path of the node that runs this, and of the daemon's main.ts. */
  node: string;
  daemon: string;
  configPaths: ConfigPaths;
};

export function plistPath(home: string): string {
  return path.join(home, 'Library', 'LaunchAgents', `${LAUNCHD_LABEL}.plist`);
}

function xml(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

/** The flags as given, with every path made absolute: launchd starts the daemon from `/`. */
export function absoluteFlags(argv: string[]): string[] {
  return argv.map((value, index) => (['--project', '--state-dir'].includes(argv[index - 1] ?? '') ? path.resolve(value) : value));
}

/** The variables the daemon gets under launchd: PATH and HOME, the marker Settings reads, and the ones that change what it runs. */
export function launchdEnvironment(env: NodeJS.ProcessEnv): Record<string, string> {
  const kept: Record<string, string> = { BRAIN_CONSOLE_LAUNCHD: '1' };
  for (const name of ['PATH', 'HOME', 'FLOW_PLUGIN', 'BRAIN_CONSOLE_PROJECTS', 'BRAIN_CONSOLE_STATE']) {
    const value = env[name];
    if (value !== undefined) kept[name] = value;
  }
  return kept;
}

/** The launch agent: node running main.ts with the flags, kept alive, started at login, its output in <state dir>/daemon.log. */
export function plistXml(options: { node: string; daemon: string; flags: string[]; env: Record<string, string>; log: string }): string {
  const strings = (values: string[], indent: string): string => values.map((value) => `${indent}<string>${xml(value)}</string>`).join('\n');
  const environment = Object.entries(options.env).map(([key, value]) => `    <key>${xml(key)}</key>\n    <string>${xml(value)}</string>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${strings([options.node, options.daemon, ...options.flags], '    ')}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
${environment}
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${xml(options.log)}</string>
  <key>StandardErrorPath</key>
  <string>${xml(options.log)}</string>
</dict>
</plist>
`;
}

/** The flags a written plist starts the daemon with, read back for `status`. */
export function flagsOfPlist(text: string): string[] {
  const array = /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(text)?.[1] ?? '';
  const values = [...array.matchAll(/<string>([\s\S]*?)<\/string>/g)].map((match) => (match[1] ?? '').replaceAll('&quot;', '"').replaceAll('&gt;', '>').replaceAll('&lt;', '<').replaceAll('&amp;', '&'));
  return values.slice(2);
}

/**
 * `install [flags]`: checks the flags as a start would, writes the launch agent, loads it
 * (`launchctl bootstrap`, or `load -w` where bootstrap fails), waits for the port and prints the URL.
 * A loaded job is booted out first, so a second install picks up new flags.
 */
export async function install(argv: string[], deps: LaunchdDependencies): Promise<number> {
  const flags = absoluteFlags(argv);
  const read = readConfig(flags, deps.env, deps.configPaths);
  if (!read.ok) { deps.print(`brain-console: ${read.error}`); return EXIT_BAD_CONFIG; }
  const { config } = read;
  const plist = plistPath(deps.home);
  const log = path.join(config.stateDir, 'daemon.log');
  deps.files.mkdir(path.dirname(plist));
  deps.files.mkdir(config.stateDir);
  deps.files.write(plist, plistXml({ node: deps.node, daemon: deps.daemon, flags, env: launchdEnvironment(deps.env), log }));
  deps.print(`wrote ${plist}`);
  const domain = `gui/${deps.uid}`;
  if ((await deps.launchctl(['print', `${domain}/${LAUNCHD_LABEL}`])).code === 0) await deps.launchctl(['bootout', `${domain}/${LAUNCHD_LABEL}`]);
  const bootstrap = await deps.launchctl(['bootstrap', domain, plist]);
  if (bootstrap.code !== 0) {
    const load = await deps.launchctl(['load', '-w', plist]);
    if (load.code !== 0) { deps.print(`brain-console: launchctl could not load ${plist}: ${(bootstrap.stderr || load.stderr).trim()}`); return EXIT_FAILED; }
  }
  if (!(await deps.waitForPort(config.host, config.port, PORT_WAIT_MS))) {
    deps.print(`brain-console: loaded, but nothing listens on ${config.port} after ${PORT_WAIT_MS / 1000}s; see ${log}`);
    return EXIT_FAILED;
  }
  deps.print(`running under launchd as ${LAUNCHD_LABEL}, on login and after a crash; output in ${log}`);
  deps.print(`http://${config.host}:${config.port}/?token=${config.token}`);
  return EXIT_OK;
}

/** `uninstall`: boots the job out of launchd and removes the plist. Nothing loaded and no file is fine. */
export async function uninstall(deps: LaunchdDependencies): Promise<number> {
  const plist = plistPath(deps.home);
  const bootout = await deps.launchctl(['bootout', `gui/${deps.uid}/${LAUNCHD_LABEL}`]);
  deps.print(bootout.code === 0 ? `stopped ${LAUNCHD_LABEL}` : `${LAUNCHD_LABEL} was not loaded`);
  if (deps.files.exists(plist)) { deps.files.remove(plist); deps.print(`removed ${plist}`); }
  return EXIT_OK;
}

/** `status`: whether launchd has the job (and its pid), and the URL it serves, from the flags in the plist. */
export async function status(deps: LaunchdDependencies): Promise<number> {
  const plist = plistPath(deps.home);
  const printed = await deps.launchctl(['print', `gui/${deps.uid}/${LAUNCHD_LABEL}`]);
  if (printed.code !== 0) {
    deps.print(`${LAUNCHD_LABEL} is not loaded${deps.files.exists(plist) ? ` (${plist} is there: npm run daemon:install loads it)` : ''}`);
    return EXIT_FAILED;
  }
  const pid = /^\s*pid = (\d+)$/m.exec(printed.stdout)?.[1];
  deps.print(`${LAUNCHD_LABEL} is loaded${pid === undefined ? ', not running now' : `, pid ${pid}`}`);
  if (!deps.files.exists(plist)) return EXIT_OK;
  const read = readConfig(flagsOfPlist(deps.files.read(plist)), { ...deps.env, ...launchdEnvironment(deps.env) }, deps.configPaths);
  if (read.ok) deps.print(`http://${read.config.host}:${read.config.port}/?token=${read.config.token}`);
  return EXIT_OK;
}
