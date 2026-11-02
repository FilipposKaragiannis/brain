import { execFile } from 'node:child_process';

/** The outcome of one external command. A non-zero exit is a value, never an exception. */
export type CommandResult = { code: number | null; stdout: string; stderr: string; timedOut: boolean };

export type CommandRequest = { command: string; args: string[]; cwd: string; timeoutMs: number; env: Record<string, string> };

/** Runs external commands. Injected so the collectors can be tested without a shell. */
export type CommandRunner = (request: CommandRequest) => Promise<CommandResult>;

const OUTPUT_LIMIT_BYTES = 64 * 1024 * 1024;

/** The variable the flow's Jira adapter takes its API token from. */
export const JIRA_TOKEN = 'JIRA_API_TOKEN';

/** The minimum environment a flow script needs. Nothing the daemon's owner exports leaks through. */
export function scriptEnvironment(): Record<string, string> {
  const environment: Record<string, string> = { LANG: 'C' };
  // FLOW_PLUGIN passes through so the owner can point the console at a plugin that is not installed.
  // JIRA_API_TOKEN is the Jira adapter's only way to its token: it never reads one from the config.
  for (const name of ['PATH', 'HOME', 'TMPDIR', 'USER', 'SHELL', 'GH_TOKEN', 'GITHUB_TOKEN', JIRA_TOKEN, 'SSH_AUTH_SOCK', 'XDG_CONFIG_HOME', 'FLOW_PLUGIN']) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

export const childProcessRunner: CommandRunner = (request) =>
  new Promise((resolve) => {
    execFile(
      request.command,
      request.args,
      { cwd: request.cwd, timeout: request.timeoutMs, maxBuffer: OUTPUT_LIMIT_BYTES, env: request.env, encoding: 'utf8' },
      (error, stdout, stderr) => {
        if (error === null) { resolve({ code: 0, stdout, stderr, timedOut: false }); return; }
        const failure = error as NodeJS.ErrnoException & { code?: number | string; killed?: boolean; signal?: string | null };
        const code = typeof failure.code === 'number' ? failure.code : null;
        const timedOut = failure.killed === true && failure.signal === 'SIGTERM';
        resolve({ code, stdout: stdout ?? '', stderr: stderr ?? (failure.message ?? ''), timedOut });
      },
    );
  });
