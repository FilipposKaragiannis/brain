import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { SyncConflict } from './snapshot.ts';

/*
 * The flow's sync note: `<reports>/sync.md`, one git ref per line, which `steward.sh`'s
 * `health_branch_notes` writes when the health job cannot merge a branch cleanly. `next.sh` finds
 * it (`[ -s "$reports/sync.md" ]`) and runs the sync step before the item's own step; a sync that
 * ends done drops it. The console writes the same file for a `worktree.sync` that conflicted, and
 * reads it back as `Worktree.syncPending`.
 */

/** The flow's `item_slug`: `tr ':/#' '---'`, so `gh#12` is `gh-12` and `local:task/7` is `local-task-7`. */
export function itemSlug(item: string): string {
  return item.replace(/[:/#]/g, '-');
}

/**
 * The flow's `reports_dir <item> <root>`: `<root>/.flow/reports/<slug>`. A work step's root is the
 * claimed worktree, and the sync step is a work step, so its note lives in the claim's worktree.
 */
export function reportsDir(worktree: string, item: string): string {
  return path.join(worktree, '.flow', 'reports', itemSlug(item));
}

export function syncNotePath(worktree: string, item: string): string {
  return path.join(reportsDir(worktree, item), 'sync.md');
}

/** The note's bytes as `health_branch_notes` writes them: `printf '%s' "ref1\nref2\n"`, every ref ending in a newline. */
export function syncNoteText(refs: string[]): string {
  return refs.map((ref) => `${ref}\n`).join('');
}

/** The refs in a note, or null for an empty file (`next.sh` tests `-s`, so an empty note is no order). */
export function parseSyncNote(text: string): string[] | null {
  if (text.length === 0) return null;
  return text.split('\n').map((line) => line.trim()).filter((line) => line !== '');
}

/** The refs the note of an item's claim names, or null when there is no note (or it is empty). */
export async function readSyncNote(worktree: string, item: string): Promise<string[] | null> {
  try { return parseSyncNote(await readFile(syncNotePath(worktree, item), 'utf8')); } catch { return null; }
}

const CONFLICT_HEAD = /^console: merging \S+ conflicts, so the merge was aborted\. Conflicting files:$/;
const STILL_TO_MERGE = /^console: still to merge: (.+)$/;

/**
 * The conflict a `worktree.sync` ended in, from `sync.sh`'s output: the files between its
 * "Conflicting files:" line and its "still to merge" line, and the refs that line names (the
 * conflicting one first, then every one the script did not get to). Null for any other ending.
 */
export function syncConflict(output: string): SyncConflict | null {
  const lines = output.split('\n');
  const head = lines.findIndex((line) => CONFLICT_HEAD.test(line));
  if (head < 0) return null;
  const tail = lines.findIndex((line, index) => index > head && STILL_TO_MERGE.test(line));
  if (tail < 0) return null;
  const refs = (STILL_TO_MERGE.exec(lines[tail]!)?.[1] ?? '').split(' ').filter((ref) => ref !== '');
  const files = lines.slice(head + 1, tail).map((line) => line.trim()).filter((line) => line !== '');
  return { refs, files };
}

/** How long the console waits for `sync.sh --refs`: three local git reads, no fetch. */
const REFS_TIMEOUT_MS = 10000;

/** The refs `sync.sh` would merge into the worktree, in its order, from what the last fetch left. */
export function syncRefs(script: string, worktree: string, base: string): string[] {
  const output = execFileSync('sh', [script, '--refs', worktree, base], { encoding: 'utf8', timeout: REFS_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'] });
  return output.split('\n').map((line) => line.trim()).filter((line) => line !== '');
}

/**
 * Writes the note for a hand-off and says what it did, for the action's output. A note already
 * there with the same refs is left alone; one with other refs is replaced, and the output names
 * what it said before, so a note the health job wrote is never overwritten unseen.
 */
export function writeSyncNote(worktree: string, item: string, refs: string[]): { output: string; replaced: string[] | null } {
  const file = syncNotePath(worktree, item);
  const text = syncNoteText(refs);
  const before = existsSync(file) ? readFileSync(file, 'utf8') : null;
  const listed = refs.map((ref) => `  ${ref}\n`).join('');
  if (before === text) return { output: `console: ${file} already names these refs, so it was left as it is:\n${listed}`, replaced: null };
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
  if (before === null) return { output: `console: wrote ${file} with the refs to merge:\n${listed}`, replaced: null };
  const old = parseSyncNote(before) ?? [];
  return { output: `console: ${file} named ${old.length === 0 ? 'nothing (it was empty)' : old.join(', ')}; replaced it with the refs to merge:\n${listed}`, replaced: old };
}
