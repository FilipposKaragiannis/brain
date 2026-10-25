import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { parseSyncNote, readSyncNote, reportsDir, syncConflict, syncNotePath, syncNoteText, writeSyncNote } from '../src/syncNote.ts';

/**
 * The flow's own writer and readers of the sync note, cut out of the plugin in this repository and
 * run with sh in a temp folder: `health_branch_notes` from steward.sh writes it, `next.sh` tests it
 * with `-s` and lists its lines in the sync step's brief, `reports_dir` in lib/flow.sh says where.
 */
const PLUGIN = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'flow');
function shellFunction(file: string, name: string): string {
  const source = readFileSync(path.join(PLUGIN, file), 'utf8');
  const start = source.indexOf(`${name}() {`);
  assert.ok(start >= 0, `because ${file} defines ${name}`);
  const oneLine = source.indexOf('\n', start);
  // A one-line function (`item_slug() { ...; }`) ends on its own line.
  if (source.slice(start, oneLine).trimEnd().endsWith('}')) return source.slice(start, oneLine + 1);
  return source.slice(start, source.indexOf('\n}\n', start) + 2);
}
function inTemp<T>(body: (dir: string) => T): T {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-sync-note-'));
  try { return body(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}

/**
 * `health_branch_notes` with what it calls stubbed: `health_branch_state` builds `health_sync` the
 * way steward.sh does for a branch that diverged from its remote and is far behind its base
 * (`"origin/<branch>\n"`, then `"$health_sync<base>\n"`), the rest only say things.
 */
function healthNote(dir: string, branch: string, base: string): string {
  const reports = path.join(dir, 'reports');
  const stubs = [
    'health_branch_state() { health_sync="origin/$3', '"; health_sync="$health_sync$4', '"; }',
  ].join('\n');
  const script = `${stubs}\nhealth_changed() { return 0; }\nhealth_say() { :; }\nhealth_cleared() { :; }\nitem_slug() { printf %s "$1"; }\n${shellFunction('scripts/steward.sh', 'health_branch_notes')}\ndry=0; health_reports="$REPORTS"\nhealth_branch_notes gh#7 "$PWD" "$BRANCH" "$BASE" 0 ""`;
  execFileSync('sh', ['-c', script], { cwd: dir, env: { ...process.env, REPORTS: reports, BRANCH: branch, BASE: base } });
  return readFileSync(path.join(reports, 'sync.md'), 'utf8');
}

test('SyncNote_SameBytesAsTheHealthJobWrites', () => {
  inTemp((dir) => {
    const written = healthNote(dir, 'flow/gh-7', 'origin/main');
    assert.equal(written, 'origin/flow/gh-7\norigin/main\n', 'because the stub must build the note as steward.sh does, or this test checks nothing');
    assert.equal(syncNoteText(['origin/flow/gh-7', 'origin/main']), written, 'because next.sh and the sync step read one format, whoever wrote the note');
  });
});

test('SyncNote_NextShFindsItAndListsEveryRef', () => {
  inTemp((dir) => {
    const reports = path.join(dir, 'reports');
    mkdirSync(reports);
    writeFileSync(path.join(reports, 'sync.md'), syncNoteText(['origin/flow/gh-7', 'origin/main']));
    const next = readFileSync(path.join(PLUGIN, 'scripts', 'next.sh'), 'utf8');
    const test = next.split('\n').find((line) => line.includes('-s "$reports/sync.md"'));
    const brief = next.split('\n').find((line) => line.trim().startsWith('sed ') && line.includes('"$reports/sync.md"'));
    assert.ok(test !== undefined && brief !== undefined, 'because next.sh tests the note and lists it in the brief');
    const found = spawnSync('sh', ['-c', '[ -s "$reports/sync.md" ]'], { env: { ...process.env, reports } });
    assert.equal(found.status, 0, 'because next.sh runs the sync step only for a note that is not empty');
    const listed = execFileSync('sh', ['-c', brief.trim()], { encoding: 'utf8', env: { ...process.env, reports } });
    assert.equal(listed, '- `origin/flow/gh-7`\n- `origin/main`\n', 'because the sync step merges each line of the note as one ref, in order');
  });
});

test('ReportsDir_MirrorsTheFlowsReportsDir', () => {
  for (const item of ['gh#12', 'local:task/7']) {
    const flow = execFileSync('sh', ['-c', `${shellFunction('lib/flow.sh', 'item_slug')}${shellFunction('lib/flow.sh', 'reports_dir')}\nreports_dir "$1" "$2"`, 'sh', item, '/p/app-wt-2'], { encoding: 'utf8' });
    assert.equal(reportsDir('/p/app-wt-2', item), flow, `because next.sh looks for ${item}'s note where reports_dir puts it`);
  }
});

test('SyncConflict_ReadsTheFilesAndTheRefsStillToMerge', () => {
  const output = 'Auto-merging a.txt\nCONFLICT (content): Merge conflict in a.txt\nconsole: merging origin/flow/gh-7 conflicts, so the merge was aborted. Conflicting files:\na.txt\nsrc/b c.ts\nconsole: still to merge: origin/flow/gh-7 origin/main\n';
  assert.deepEqual(syncConflict(output), { refs: ['origin/flow/gh-7', 'origin/main'], files: ['a.txt', 'src/b c.ts'] }, 'because the hand-off needs the refs left and the owner the files to look at');
});

test('SyncConflict_OtherEndings_Null', () => {
  for (const output of ['console: merged origin/main\n', 'console: git could not merge origin/main\n', 'console: git fetch origin failed\n']) {
    assert.equal(syncConflict(output), null, `because "${output.trim()}" is no conflict to hand off`);
  }
});

test('WriteSyncNote_NoNote_WritesItAndSaysWhere', () => {
  inTemp((dir) => {
    const written = writeSyncNote(dir, 'gh#7', ['origin/main']);
    assert.equal(readFileSync(syncNotePath(dir, 'gh#7'), 'utf8'), 'origin/main\n', 'because the note is one ref per line');
    assert.match(written.output, /wrote .*\.flow\/reports\/gh-7\/sync\.md with the refs to merge:\n {2}origin\/main\n/, 'because the output says what was written and where');
    assert.equal(written.replaced, null, 'because nothing was there before');
  });
});

test('WriteSyncNote_SameNote_LeftAndSaid', () => {
  inTemp((dir) => {
    writeSyncNote(dir, 'gh#7', ['origin/main']);
    const again = writeSyncNote(dir, 'gh#7', ['origin/main']);
    assert.match(again.output, /already names these refs/, 'because a note the health job wrote with the same refs needs no write');
  });
});

test('WriteSyncNote_OtherNote_ReplacedAndTheOldRefsNamed', () => {
  inTemp((dir) => {
    mkdirSync(path.dirname(syncNotePath(dir, 'gh#7')), { recursive: true });
    writeFileSync(syncNotePath(dir, 'gh#7'), 'origin/flow/gh-7\norigin/main\n');
    const written = writeSyncNote(dir, 'gh#7', ['origin/main']);
    assert.match(written.output, /named origin\/flow\/gh-7, origin\/main; replaced it/, 'because a note with other refs is never overwritten unseen');
    assert.deepEqual(written.replaced, ['origin/flow/gh-7', 'origin/main'], 'because the log names what was replaced');
  });
});

test('ReadSyncNote_EmptyOrMissing_Null', async () => {
  assert.equal(parseSyncNote(''), null, 'because next.sh tests -s, so an empty note orders nothing');
  assert.equal(await readSyncNote('/nonexistent', 'gh#7'), null, 'because no note is no pending sync');
});
