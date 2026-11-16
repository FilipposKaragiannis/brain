import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { ProcessEntry } from '../src/ptyGroups.ts';
import { paneGroups } from '../src/ptyGroups.ts';

const SHELL = 100;
const JOB = 200;
const JOB_CHILD = 201;
const STRANGER = 300;
const INIT = 1;

function sorted(groups: Set<number>): number[] {
  return [...groups].sort((left, right) => left - right);
}

test('PaneGroups_ShellStartedAJobInItsOwnGroup_JobGroupIsThePanes', () => {
  const table: ProcessEntry[] = [
    { pid: SHELL, parentPid: INIT, groupId: SHELL },
    { pid: JOB, parentPid: SHELL, groupId: JOB },
  ];
  assert.deepEqual(sorted(paneGroups(table, new Set([SHELL]))), [SHELL, JOB], 'because job control puts a foreground command in a group the shell does not lead');
});

test('PaneGroups_ShellEndedAndItsJobWasReparented_KnownJobGroupStaysThePanes', () => {
  const table: ProcessEntry[] = [
    { pid: JOB, parentPid: INIT, groupId: JOB },
    { pid: JOB_CHILD, parentPid: JOB, groupId: JOB_CHILD },
  ];
  assert.deepEqual(sorted(paneGroups(table, new Set([SHELL, JOB]))), [SHELL, JOB, JOB_CHILD], 'because a job left behind keeps its group, and what it starts is the pane\'s too');
});

test('PaneGroups_ProcessOutsideThePane_NotThePanes', () => {
  const table: ProcessEntry[] = [
    { pid: SHELL, parentPid: INIT, groupId: SHELL },
    { pid: STRANGER, parentPid: INIT, groupId: STRANGER },
  ];
  assert.deepEqual(sorted(paneGroups(table, new Set([SHELL]))), [SHELL], 'because closing a pane never signals a process it did not start');
});
