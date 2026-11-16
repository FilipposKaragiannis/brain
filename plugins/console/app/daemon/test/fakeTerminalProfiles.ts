import { silentLogger } from '../src/log.ts';
import { TerminalProfiles } from '../src/terminalProfiles.ts';

/** The panes' look on a machine with no iTerm and no font to serve: the server's routes answer, nothing is read from the disk. */
export function noTerminalProfiles(): TerminalProfiles {
  return new TerminalProfiles({ readItermPreferences: async () => null, findFont: async () => null }, silentLogger, new AbortController().signal);
}
