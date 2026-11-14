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

/** A word as POSIX sh reads it back whole, whatever quotes, spaces or `$` it holds. */
export function shellQuote(word: string): string {
  return `'${word.replaceAll("'", `'\\''`)}'`;
}

/** A word a person can read and type: plain when sh would read it back whole, else quoted. */
function typedWord(word: string): string {
  return /^[A-Za-z0-9_./:=@%+,-]+$/.test(word) ? word : shellQuote(word);
}

/** The resume command as the owner would type it, such as `claude --resume 8f3c…`. */
export function commandText(argv: string[]): string {
  return argv.map(typedWord).join(' ');
}
