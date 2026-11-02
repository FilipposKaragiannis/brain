import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config.ts';
import type { DaemonConfig } from '../src/config.ts';
import { childProcessRunner } from '../src/collectors/exec.ts';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { readGit } from '../src/collectors/git.ts';
import { SettingsStore } from '../src/settings.ts';
import { fakeRunner, FIXTURE_ROOT } from './fakeRunner.ts';

// flow:init keeps .flow/ out of git: a block in the clone's .git/info/exclude, nothing committed.
// The console reads the flow home from the disk, so such a project is added and watched as one
// whose .flow/ was committed.

type ExcludedProject = { root: string; linked: string; cleanup: () => void };

function gitIn(cwd: string, args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' } });
}

/** A git repo with one commit, .flow/ excluded and untracked, a pool worktree beside it holding a claim. */
function excludedProject(): ExcludedProject {
  const dir = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'console-excluded-')));
  const root = path.join(dir, 'app');
  const linked = path.join(dir, 'app-wt-1');
  mkdirSync(root);
  gitIn(root, ['init', '-q', '-b', 'main']);
  gitIn(root, ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init']);
  gitIn(root, ['worktree', 'add', '-q', '--detach', linked]);
  writeFileSync(path.join(root, '.git', 'info', 'exclude'), '# flow:begin (written by flow:init)\n.flow/\n# flow:end\n');
  mkdirSync(path.join(root, '.flow'));
  writeFileSync(path.join(root, '.flow', 'config.yaml'), 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\n');
  mkdirSync(path.join(linked, '.flow'));
  writeFileSync(path.join(linked, '.flow', 'claim.json'), JSON.stringify({ item: 'local:task/1', worktree: linked, claimed_at: '2026-11-02T10:00:00Z' }));
  return { root, linked, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function settingsStore(): { settings: SettingsStore; cleanup: () => void } {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-excluded-settings-'));
  writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ projects: [{ root: FIXTURE_ROOT }] }));
  const paths = { configFile: path.join(dir, 'config.json'), legacyProjectsFile: path.join(dir, 'projects.json') };
  const read = readConfig([], { BRAIN_CONSOLE_TOKEN: 't', BRAIN_CONSOLE_STATE: dir }, paths);
  assert.ok(read.ok, 'because the test config is valid');
  const config = (read as { config: DaemonConfig }).config;
  const settings = new SettingsStore({ config, installed: () => ['terminal'], applyProjects: () => undefined, newerConsole: () => null });
  return { settings, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('ExcludedFlow_Fixture_GitTracksNothingAndSeesNoChange', () => {
  const project = excludedProject();
  try {
    assert.equal(gitIn(project.root, ['ls-files', '.flow']), '', 'because init leaves .flow/ untracked');
    assert.equal(gitIn(project.root, ['status', '--porcelain', '--untracked-files=all']), '', 'because the exclude hides .flow/ from git status');
  } finally { project.cleanup(); }
});

test('AddProject_FlowExcludedFromGit_EveryFindingOkAndThePutTakesIt', () => {
  const project = excludedProject();
  const { settings, cleanup } = settingsStore();
  try {
    const check = settings.checkProject(project.root);
    assert.deepEqual(check.findings.filter((finding) => !finding.ok).map((finding) => finding.check), [], 'because the config is on the disk, whatever git tracks');
    assert.ok(check.ok, 'because the PUT that adds it takes the same check');
  } finally { cleanup(); project.cleanup(); }
});

test('ProjectStatus_FlowExcludedFromGit_ConfigAndClaimRead', async () => {
  const project = excludedProject();
  try {
    const facts = await readFlowHome(project.root, fakeRunner);
    assert.equal(facts.config.base, 'main', 'because the config is read from the main worktree\'s .flow on the disk');
    assert.deepEqual(facts.claims.map((claim) => claim.item), ['local:task/1'], 'because the claim in the pool worktree is read from the disk, though git ignores it');
  } finally { project.cleanup(); }
});

test('ProjectStatus_FlowExcludedFromGit_WorktreesCountNoDirtyFiles', async () => {
  const project = excludedProject();
  try {
    const facts = await readGit(project.root, 'main', childProcessRunner);
    assert.deepEqual(facts.worktrees.map((worktree) => [worktree.path, worktree.dirtyFiles]), [[project.root, 0], [project.linked, 0]], 'because the shared exclude hides the flow home and the claim file from both worktrees');
  } finally { project.cleanup(); }
});
