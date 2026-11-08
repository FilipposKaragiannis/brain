import path from 'node:path';
import type { AgentHost, AgentKind } from '../snapshot.ts';
import { hostCommand, splitCommand } from './commandLine.ts';

/** A row of the process read as far as an agent's lineage looks into it. */
export type ProcessLink = { pid: number; parentPid: number; command: string };

/** flow's unattended loop, which the next job runs, and a job's own script, `jobs/<name>.sh`. */
const LOOP_SCRIPT = /(^|\/)run-unattended\.sh$/;
const JOB_SCRIPT = /(^|\/)jobs\/(?<name>[a-z][a-z0-9-]*)\.sh$/;
/** The job the unattended loop runs for. */
const LOOP_JOB = 'next';
/** How many parents up an agent's job is looked for; flow's own chain is a handful deep. */
const MAX_PARENTS = 32;
/** codex's options that name its working root: `codex exec -C <dir>`, `--cd <dir>` or `--cd=<dir>`. */
const CODEX_WORKING_ROOT = ['-C', '--cd'];
const CODEX_WORKING_ROOT_JOINED = '--cd=';
/** codex's other options that take a value (`codex exec --help`), whose value is never its prompt. */
const CODEX_OPTIONS_WITH_VALUE = [
  '-c', '--config', '-m', '--model', '-s', '--sandbox', '-p', '--profile', '-i', '--image', '-a', '--ask-for-approval',
  '-o', '--output-last-message', '--output-schema', '--color', '--add-dir', '--enable', '--disable', '--local-provider',
];
/** The subcommand of an unattended codex run, and the word after which every word is the prompt. */
const CODEX_EXEC = 'exec';
const END_OF_OPTIONS = '--';

/** Whether the word at `index` ends codex's options: `--`, or a word that is neither an option nor the `exec` subcommand, the prompt. */
function endsCodexOptions(words: string[], index: number): boolean {
  const word = words[index]!;
  if (word === END_OF_OPTIONS) return true;
  return !word.startsWith('-') && !(word === CODEX_EXEC && words.indexOf(CODEX_EXEC) === index);
}

/** The `-C`/`--cd` directory among codex's options, or null when they name none before the prompt. */
function codexWorkingRoot(words: string[]): string | null {
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]!;
    if (word.startsWith(CODEX_WORKING_ROOT_JOINED)) return word.slice(CODEX_WORKING_ROOT_JOINED.length);
    if (CODEX_WORKING_ROOT.includes(word)) return words[index + 1] ?? null;
    if (CODEX_OPTIONS_WITH_VALUE.includes(word)) { index += 1; continue; }
    if (endsCodexOptions(words, index)) return null;
  }
  return null;
}

/**
 * Where an agent works. `codex exec -C <dir>` (how flow's host.sh starts a Codex run) works in
 * `<dir>` but keeps the cwd it was started in, so lsof gives the launch folder, such as the
 * project root: for a codex exec the `-C`/`--cd` directory, resolved against that cwd, wins
 * when its options name one before the prompt. Every other process works in the cwd lsof gave.
 * ps prints the argv unquoted, so a directory with a space in it is cut at the space.
 */
export function workingDirectory(host: AgentHost, kind: AgentKind, command: string, cwd: string): string {
  if (host !== 'codex' || kind !== 'agent') return cwd;
  const named = codexWorkingRoot(splitCommand(command).arguments);
  return named === null ? cwd : path.resolve(cwd, named);
}

/**
 * The flow job a process runs as its script, or null: `next` for the unattended loop
 * (`run-unattended.sh`), else `<name>` for `jobs/<name>.sh`. The script is the program or its
 * first argument that is not an option (`/bin/sh …/jobs/comments.sh claude`), so a shell whose
 * `-c` string only names the script is not the job. A claude or codex never is, whatever its
 * prompt names (`claude -p jobs/comments.sh fails`).
 */
export function jobOf(command: string): string | null {
  if (hostCommand(command) !== null) return null;
  const { executable, arguments: words } = splitCommand(command);
  for (const word of [executable, words.find((entry) => !entry.startsWith('-')) ?? '']) {
    if (LOOP_SCRIPT.test(word)) return LOOP_JOB;
    const name = JOB_SCRIPT.exec(word)?.groups?.['name'];
    if (name !== undefined) return name;
  }
  return null;
}

/**
 * The pids above a row, nearest first, and the job of the nearest one that runs a flow job's
 * script, from the one ps read: a parent ps did not list, a loop or `MAX_PARENTS` ends the chain.
 */
export function lineage(row: ProcessLink, byPid: Map<number, ProcessLink>): { parents: number[]; job: string | null } {
  const parents: number[] = [];
  let job: string | null = null;
  for (let parent = byPid.get(row.parentPid); parent !== undefined && parents.length < MAX_PARENTS; parent = byPid.get(parent.parentPid)) {
    if (parent.pid === row.pid || parents.includes(parent.pid)) break;
    parents.push(parent.pid);
    job ??= jobOf(parent.command);
  }
  return { parents, job };
}
