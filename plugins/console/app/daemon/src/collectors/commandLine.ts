import type { AgentHost } from '../snapshot.ts';

/**
 * App bundles and the folder the Claude desktop app keeps its CLI in. The executable runs past a
 * space only while the part beyond it is still one of these paths, so `sh /usr/local/bin/claude`
 * or `node …/claude` is a wrapper, never the host.
 */
const PATH_WITH_SPACES = ['.app/', 'Application Support/'];
const HOSTS: AgentHost[] = ['claude', 'codex'];
/** How many of the first words after the executable a server's label reads (`app-server daemon`). */
const SUBCOMMAND_WORDS = 2;
/** Options that take a value: `codex -c key=value app-server`. */
const OPTIONS_WITH_VALUE = ['-c', '--config'];

/** The executable and its arguments. ps prints the command unquoted, so a path with spaces is rejoined. */
export function splitCommand(command: string): { executable: string; arguments: string[] } {
  const tokens = command.split(' ').filter((token) => token.length > 0);
  let executable = tokens[0] ?? '';
  let next = 1;
  while (next < tokens.length) {
    const extended = `${executable} ${tokens[next]}`;
    const spansTheSpace = PATH_WITH_SPACES.some((marker) => {
      const at = extended.lastIndexOf(marker);
      return at >= 0 && at + marker.length > executable.length + 1;
    });
    if (!spansTheSpace) break;
    executable = extended;
    next += 1;
  }
  return { executable, arguments: tokens.slice(next) };
}

/** The first words after the executable that are not options, such as `app-server daemon`. */
function subcommands(words: string[]): string[] {
  const found: string[] = [];
  for (let index = 0; index < words.length && found.length < SUBCOMMAND_WORDS; index += 1) {
    const word = words[index]!;
    if (OPTIONS_WITH_VALUE.includes(word)) { index += 1; continue; }
    if (word.startsWith('-')) continue;
    found.push(word);
  }
  return found;
}

/** The host a command runs and the first words after it, or null when it runs neither claude nor codex. */
export function hostCommand(command: string): { host: AgentHost; words: string[] } | null {
  const { executable, arguments: words } = splitCommand(command);
  const name = executable.slice(executable.lastIndexOf('/') + 1);
  const host = HOSTS.find((entry) => entry === name);
  return host === undefined ? null : { host, words: subcommands(words) };
}
