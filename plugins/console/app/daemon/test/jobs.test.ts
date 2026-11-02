import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { parseJobStatus, parseRunLines, readJobs, readRunTail } from '../src/collectors/jobs.ts';
import { FAKE_PLUGIN, fakeRunner } from './fakeRunner.ts';

/** A run log line as `job_record` in the plugin's jobs/_job.sh writes it. */
const line = (job: string, at: string, result: string, exit = 0): string => JSON.stringify({ job, host: 'claude', at, seconds: 0, exit, result });
/** A step line as `host_record` in lib/host.sh writes it: no job, so no job reader takes it. */
const STEP_LINE = JSON.stringify({ item: 'gh#7', step: 'implement', host: 'claude', model: '', effort: '', at: '2026-10-24T17:10:00Z', seconds: 600, exit: 0, usage: { input: 1 }, cost_usd: 0.5, models: [], result: '' });

function withLogDir<T>(body: (logDir: string, root: string) => Promise<T>): Promise<T> {
  const root = mkdtempSync(path.join(os.tmpdir(), 'console-runs-'));
  const logDir = path.join(root, '.flow', 'log');
  mkdirSync(logDir, { recursive: true });
  return body(logDir, root).finally(() => rmSync(root, { recursive: true, force: true }));
}

test('RunLines_StepLinesAndNoise_PassedOver', () => {
  const text = [line('next-1', '2026-10-24T17:00:00Z', 'skipped: run 36596 still going'), STEP_LINE, 'not json', '[1]', JSON.stringify({ job: '' }), JSON.stringify({ job: 'retro', result: 42 }), ''].join('\n');
  const runs = parseRunLines(text);
  assert.deepEqual(runs.map((run) => [run.job, run.result]), [['next-1', 'skipped: run 36596 still going'], ['retro', '42']], "because only a line with a job name is a job's run, as flow's own reader takes them, and a result of digits is text");
});

test('RunTail_FileLongerThanTheBound_OnlyItsEndRead', async () => {
  await withLogDir(async (logDir) => {
    const lines = Array.from({ length: 200 }, (_, index) => line('health', `2026-10-24T00:00:${String(index % 60).padStart(2, '0')}Z`, `quiet: pass ${index}`));
    writeFileSync(path.join(logDir, 'runs.jsonl'), `${lines.join('\n')}\n`);
    const runs = await readRunTail(logDir, 1000);
    assert.ok(runs.length > 0 && runs.length < 20, `because only the last kilobyte is read, not the whole file (read ${runs.length})`);
    assert.equal(runs.at(-1)?.result, 'quiet: pass 199', 'because the newest line is at the end of the file');
    assert.ok(runs.every((run) => run.result.startsWith('quiet: pass')), 'because the line the bound cut in two is dropped, not parsed as half a record');
  });
});

test('RunTail_ShortFileAfterRotation_TopsUpFromTheRotatedFile', async () => {
  await withLogDir(async (logDir) => {
    writeFileSync(path.join(logDir, 'runs.1.jsonl'), `${line('next', '2026-10-23T10:00:00Z', 'done, 1 step')}\n`);
    writeFileSync(path.join(logDir, 'runs.jsonl'), `${line('next', '2026-10-24T10:00:00Z', 'quiet: nothing ready')}\n`);
    const runs = await readRunTail(logDir);
    assert.deepEqual(runs.map((run) => run.at), ['2026-10-23T10:00:00Z', '2026-10-24T10:00:00Z'], 'because job_record just moved the log to runs.1.jsonl, and its runs are still the latest, oldest first as flow reads the two');
  });
});

test('RunTail_NoLog_NoRuns', async () => {
  await withLogDir(async (logDir) => {
    assert.deepEqual(await readRunTail(logDir), [], 'because a project whose jobs never ran has no run log');
  });
});

test('ReadJobs_StatusRowsAndTheRunLogOfTheProject', async () => {
  await withLogDir(async (logDir, root) => {
    writeFileSync(path.join(logDir, 'runs.jsonl'), `${line('next-2', '2026-10-24T17:30:00Z', 'skipped: run 36596 still going')}\n`);
    const facts = await readJobs(root, FAKE_PLUGIN, fakeRunner);
    assert.deepEqual([facts.jobs.map((row) => row.job), facts.runs.map((run) => run.job)], [['next', 'health', 'retro'], ['next-2']], "because the rows come from jobs.sh status and the runs from <flow home>/log/runs.jsonl");
  });
});

/** A status row of `jobs.sh status --json` with the fields every plugin prints, and the ones given. */
const statusRow = (fields: Record<string, unknown>): Record<string, unknown> => ({ schedule: 'every 30m', args: '', installed: true, paused: false, loaded: true, running: [], week: {}, last: null, next: '18:00', ...fields });

test('JobStatus_NamedSchedulesWithHostAndConfigured_ReadAsFlowPrintsThem', () => {
  const rows = parseJobStatus(JSON.stringify([
    statusRow({ job: 'next-nightly', host: 'codex', configured: true }),
    statusRow({ job: 'retro-old', host: 'claude', configured: false }),
    statusRow({ name: 'comments-fast', job: 'comments', host: 'claude' }),
  ]));
  assert.deepEqual(rows.map((row) => [row.name, row.job, row.host, row.configured]), [
    ['next-nightly', 'next', 'codex', true],
    ['retro-old', 'retro', 'claude', false],
    ['comments-fast', 'comments', 'claude', true],
  ], 'because a schedule runs the job its name opens with, and an installed one the config no longer names is not configured');
});

test('JobStatus_OlderPluginWithoutTheNewFields_Defaulted', () => {
  const [row] = parseJobStatus(JSON.stringify([statusRow({ job: 'health', host: '' })]));
  assert.deepEqual([row?.name, row?.job, row?.host, row?.configured], ['health', 'health', null, true], 'because before named schedules every row was a job of its own name, on a host it did not say, and in the config');
});
