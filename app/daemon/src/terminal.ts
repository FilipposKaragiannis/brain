import path from 'node:path';

import type { TerminalName } from './snapshot.ts';

export type { TerminalName };
export const TERMINAL_NAMES: TerminalName[] = ['iterm', 'terminal', 'ghostty'];

/** The app bundle of each terminal, in the order the console picks one when none is set. */
const APPS: { name: TerminalName; app: string }[] = [
  { name: 'iterm', app: 'iTerm' },
  { name: 'ghostty', app: 'Ghostty' },
  { name: 'terminal', app: 'Terminal' },
];

/**
 * The terminals installed on this Mac, first choice first: an app is installed when its bundle
 * is in /Applications or ~/Applications (Terminal also in /System/Applications/Utilities, where
 * macOS keeps it). `exists` is injected so a test never looks at the disk.
 */
export function installedTerminals(exists: (file: string) => boolean, home: string): TerminalName[] {
  return APPS.filter(({ name, app }) => {
    const folders = ['/Applications', path.join(home, 'Applications'), ...(name === 'terminal' ? ['/System/Applications/Utilities'] : [])];
    return folders.some((folder) => exists(path.join(folder, `${app}.app`)));
  }).map(({ name }) => name);
}

/** One process that opens a terminal: a program and its argv, never a shell line. */
export type TerminalLaunch = { command: string; args: string[] };

export type LaunchResult = { ok: true; launch: TerminalLaunch } | { ok: false; error: string };

/** A word as POSIX sh reads it back whole, whatever quotes, spaces or `$` it holds. */
export function shellQuote(word: string): string {
  return `'${word.replaceAll("'", `'\\''`)}'`;
}

/** Text as an AppleScript string literal: only the backslash and the double quote need escaping. */
export function appleScriptString(text: string): string {
  return `"${text.replace(/[\\"]/g, (character) => `\\${character}`)}"`;
}

/** The shell line a terminal runs to follow something in a folder: every word quoted, so no path can end it early. */
export function shellLine(folder: string, run: string[]): string {
  return `cd ${shellQuote(folder)} && ${run.map(shellQuote).join(' ')}`;
}

/**
 * How to open `folder` in the chosen terminal, or in the first installed one when none is set.
 * With `run` (an argv such as `tail -n 200 -f <log>`) the new window runs it in that folder:
 * iTerm and Terminal through osascript with the line quoted for sh and then for AppleScript,
 * Ghostty with the line as the one word after `-e` (whether Ghostty runs that word through a
 * shell or joins its -e words into one, the line comes out the same), a custom command with
 * `{cmd}` replaced by the line. In a custom command `{path}` is the folder as it is, for a word
 * of its own in the argv; `{qpath}` is the folder quoted for sh, for use inside an `sh -c`
 * string, as `{cmd}` already is. The folder goes last when no word names `{path}` or `{qpath}`.
 */
export function terminalLaunch(setting: TerminalName | { command: string[] } | null, installed: TerminalName[], folder: string, run: string[] | null): LaunchResult {
  const chosen = setting ?? installed[0] ?? null;
  if (chosen === null) return { ok: false, error: 'no terminal app found (iTerm, Ghostty or Terminal); pick one or set a command in Settings' };
  const line = run === null ? null : shellLine(folder, run);
  if (typeof chosen === 'object') {
    const words = chosen.command.map((word) => word.replaceAll('{qpath}', shellQuote(folder)).replaceAll('{path}', folder).replaceAll('{cmd}', line ?? ''));
    const withPath = chosen.command.some((word) => word.includes('{path}') || word.includes('{qpath}')) ? words : [...words, folder];
    const [command, ...args] = withPath;
    return { ok: true, launch: { command: command ?? '', args } };
  }
  switch (chosen) {
    case 'iterm':
      if (line === null) return { ok: true, launch: { command: 'open', args: ['-a', 'iTerm', folder] } };
      // iTerm runs the command itself, not through a shell, so the line goes to sh as one argument.
      return { ok: true, launch: { command: 'osascript', args: ['-e', `tell application "iTerm" to create window with default profile command ${appleScriptString(`/bin/sh -c ${shellQuote(line)}`)}`, '-e', 'tell application "iTerm" to activate'] } };
    case 'terminal':
      if (line === null) return { ok: true, launch: { command: 'open', args: ['-a', 'Terminal', folder] } };
      return { ok: true, launch: { command: 'osascript', args: ['-e', `tell application "Terminal" to do script ${appleScriptString(line)}`, '-e', 'tell application "Terminal" to activate'] } };
    case 'ghostty':
      return { ok: true, launch: { command: 'open', args: ['-na', 'Ghostty', '--args', `--working-directory=${folder}`, ...(line === null ? [] : ['-e', line])] } };
  }
}

/** A word a person can read and type: plain when sh would read it back whole, else quoted. */
function typedWord(word: string): string {
  return /^[A-Za-z0-9_./:=@%+,-]+$/.test(word) ? word : shellQuote(word);
}

/** The resume command as the owner would type it, such as `claude --resume 8f3c…`. */
export function commandText(argv: string[]): string {
  return argv.map(typedWord).join(' ');
}

/** After the line, the window keeps a shell, so Ghostty and a custom command do not close when the command ends. */
const KEEP_SHELL = 'exec "${SHELL:-/bin/sh}" -l';

/**
 * How to hand the owner a session: a terminal at `folder` with its resume command. While the
 * process still runs (`alive`) the command must not run yet (two writers on one session), so
 * iTerm types it without pressing Enter (`write text … newline NO`); Terminal and Ghostty cannot
 * type without running, so they print it with `echo` and leave the shell. Once the process has
 * ended the command runs at once. A custom command gets the same line as Terminal in `{cmd}`.
 */
export function sessionLaunch(setting: TerminalName | { command: string[] } | null, installed: TerminalName[], folder: string, resume: string[], alive: boolean): LaunchResult {
  const chosen = setting ?? installed[0] ?? null;
  if (chosen === null) return { ok: false, error: 'no terminal app found (iTerm, Ghostty or Terminal); pick one or set a command in Settings' };
  const typed = commandText(resume);
  const printed = `echo ${shellQuote('The run is still going. Once it ends, resume its session with:')} && echo ${shellQuote(typed)}`;
  const line = `cd ${shellQuote(folder)} && ${alive ? printed : typed}`;
  if (typeof chosen === 'object') {
    const words = chosen.command.map((word) => word.replaceAll('{qpath}', shellQuote(folder)).replaceAll('{path}', folder).replaceAll('{cmd}', `${line}; ${KEEP_SHELL}`));
    const withPath = chosen.command.some((word) => word.includes('{path}') || word.includes('{qpath}')) ? words : [...words, folder];
    const [command, ...args] = withPath;
    return { ok: true, launch: { command: command ?? '', args } };
  }
  switch (chosen) {
    case 'iterm': {
      const script = [
        'tell application "iTerm"',
        'activate',
        'set sessionWindow to (create window with default profile)',
        'tell current session of sessionWindow',
        `write text ${appleScriptString(`cd ${shellQuote(folder)}`)}`,
        `write text ${appleScriptString(typed)}${alive ? ' newline NO' : ''}`,
        'end tell',
        'end tell',
      ];
      return { ok: true, launch: { command: 'osascript', args: script.flatMap((statement) => ['-e', statement]) } };
    }
    case 'terminal':
      return { ok: true, launch: { command: 'osascript', args: ['-e', `tell application "Terminal" to do script ${appleScriptString(line)}`, '-e', 'tell application "Terminal" to activate'] } };
    case 'ghostty':
      return { ok: true, launch: { command: 'open', args: ['-na', 'Ghostty', '--args', `--working-directory=${folder}`, '-e', `${line}; ${KEEP_SHELL}`] } };
  }
}
