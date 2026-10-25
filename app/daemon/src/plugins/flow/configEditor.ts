import { createHash } from 'node:crypto';
import { chmod, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { CommandRunner } from '../../collectors/exec.ts';
import { scriptEnvironment } from '../../collectors/exec.ts';
import type { Logger } from '../../log.ts';
import { parseYaml } from '../../yaml.ts';
import type { YamlMap } from '../../yaml.ts';
import { applyChange, leafPaths, parseDocument, readsBack, valueAt } from './configDocument.ts';
import { readHostDefaults } from './hostDefaults.ts';
import type { FieldChange, FieldSpec, FieldValue, FlowConfigDocument, FlowConfigSaved, FollowUp, HostDefaults, Section } from './schema.ts';
import { checkChange, checkFileValue, fieldAt, fieldCovering, FLOW_CONFIG_SCHEMA, OTHER_GROUP, schemaSections } from './schema.ts';

export type FlowConfigEditorDependencies = {
  projectId: string;
  root: string;
  /** Asks git whether the file has uncommitted changes. Injected, so a test never runs git. */
  runner: CommandRunner;
  /** Re-reads the sources the file feeds (`files` and `jobs`), so the snapshot shows the saved file before the reply goes out. */
  refresh: () => Promise<void>;
  log: Logger;
  /** The home folder `~/.codex/config.toml` is read from, for the hosts' defaults; the user's own when omitted. */
  home?: string;
};

export type EditorReply = { status: number; body: unknown };

const HTTP_OK = 200;
const HTTP_BAD_REQUEST = 400;
const HTTP_NOT_FOUND = 404;
const HTTP_CONFLICT = 409;
const GIT_TIMEOUT_MS = 10000;
const CONFIG_FILE = path.join('.flow', 'config.yaml');
const PATH = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/;
const OTHER_HELP = 'Not a key the console knows: edited as text, as the file holds it.';

export function contentHash(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}

type Shape = 'scalar' | 'list' | 'map';

function shapeOf(spec: FieldSpec | undefined, value: FieldValue): Shape {
  const type = spec?.type;
  if (type === 'list' || type === 'map') return type;
  if (type !== undefined) return 'scalar';
  if (Array.isArray(value)) return 'list';
  return 'scalar';
}

/** The keys in the file the schema does not cover, each as text (or a list), in file order. */
function otherFields(values: YamlMap): FieldSpec[] {
  return leafPaths(values).flatMap((leaf) => {
    if (fieldCovering(leaf) !== undefined) return [];
    const value = valueAt(values, leaf);
    // An empty map (`auto_gates:` with only a commented example) has nothing to edit.
    if (value !== undefined && typeof value === 'object' && !Array.isArray(value)) return [];
    return [{ path: leaf, type: Array.isArray(value) ? 'list' as const : 'string' as const, group: OTHER_GROUP, help: OTHER_HELP, followUp: null }];
  });
}

const NO_HOST_DEFAULTS: HostDefaults = { codex: null };

/** The file as the editor shows it: its text and hash, the values, the schema's sections plus Other, what does not fit, and the hosts' defaults given. */
export function describe(file: string, text: string, hostDefaults: HostDefaults = NO_HOST_DEFAULTS): FlowConfigDocument {
  const parsed = parseDocument(text);
  const sections: Section[] = schemaSections();
  if (!parsed.ok) return { path: file, text, hash: contentHash(text), values: null, sections, warnings: [`not in the flat format, so only Raw YAML can change it: ${parsed.error}`], hostDefaults };
  const values = parseYaml(text);
  const warnings = FLOW_CONFIG_SCHEMA.flatMap((spec) => {
    const value = valueAt(values, spec.path);
    if (value === undefined) return [];
    const checked = checkFileValue(spec, value);
    return checked.ok ? [] : [checked.error];
  });
  const other = otherFields(values);
  return { path: file, text, hash: contentHash(text), values, sections: other.length > 0 ? [...sections, { group: OTHER_GROUP, fields: other }] : sections, warnings, hostDefaults };
}

/** The leaf paths whose value differs between two versions of the file. */
function changedPaths(before: YamlMap, after: YamlMap): string[] {
  const all = [...new Set([...leafPaths(before), ...leafPaths(after)])];
  return all.filter((leaf) => JSON.stringify(valueAt(before, leaf)) !== JSON.stringify(valueAt(after, leaf)));
}

const SCHEDULE_PREFIX = 'jobs.schedule.';

/** The jobs whose schedule the new file leaves out or empty, among the changed keys. */
function unscheduled(paths: string[], after: YamlMap): string[] {
  return paths.filter((changed) => changed.startsWith(SCHEDULE_PREFIX)).filter((changed) => {
    const value = valueAt(after, changed);
    return value === undefined || value === '';
  }).map((changed) => changed.slice(SCHEDULE_PREFIX.length));
}

/**
 * What the changed keys need next, one entry per follow-up with the keys that need it.
 * `jobs.sh install` loads only jobs that still have a schedule (and exits 2 when none has), so a
 * job whose schedule went gets its own `jobs.sh uninstall <job>`, and the install is offered only
 * while some schedule is left.
 */
export function followUpsOf(paths: string[], after: YamlMap): (FollowUp & { paths: string[] })[] {
  const found = new Map<string, FollowUp & { paths: string[] }>();
  const removed = unscheduled(paths, after);
  for (const job of removed) {
    found.set(`uninstall ${job}`, {
      note: `jobs.sh install loads only jobs with a schedule, so ${job}'s launchd agent keeps running until jobs.sh uninstall ${job} unloads it.`,
      action: { kind: 'job.uninstall', label: `Unload ${job}`, args: { job } }, paths: [`${SCHEDULE_PREFIX}${job}`],
    });
  }
  const scheduled = Object.values((valueAt(after, 'jobs.schedule') ?? {}) as Record<string, unknown>).some((value) => typeof value === 'string' && value !== '');
  for (const changed of paths) {
    // A schedule that went needs its uninstall above, not an install.
    if (removed.some((job) => changed === `${SCHEDULE_PREFIX}${job}`)) continue;
    const followUp = (fieldAt(changed) ?? fieldCovering(changed))?.followUp ?? null;
    if (followUp === null) continue;
    if (followUp.action?.kind === 'jobs.install' && !scheduled) continue;
    const entry = found.get(followUp.note) ?? { ...followUp, paths: [] };
    entry.paths.push(changed);
    found.set(followUp.note, entry);
  }
  return [...found.values()];
}

type Request = { kind: 'changes'; changes: FieldChange[]; hash: string; force: boolean } | { kind: 'text'; text: string; hash: string; force: boolean };

function readRequest(body: unknown): Request | string {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return 'send {"changes": [{"path", "value"}], "hash"} or {"text", "hash"}';
  const record = body as Record<string, unknown>;
  const stray = Object.keys(record).find((key) => !['changes', 'text', 'hash', 'force'].includes(key));
  if (stray !== undefined) return `unknown field: ${stray}`;
  if (typeof record['hash'] !== 'string' || record['hash'] === '') return 'send the hash the file was read with, so a change made on disk since is not overwritten';
  if (record['force'] !== undefined && typeof record['force'] !== 'boolean') return 'force must be true or false';
  const force = record['force'] === true;
  if ((record['changes'] === undefined) === (record['text'] === undefined)) return 'send either changes or text, not both';
  if (typeof record['text'] === 'string') return { kind: 'text', text: record['text'], hash: record['hash'], force };
  if (record['text'] !== undefined) return 'text must be the whole file as a string';
  if (!Array.isArray(record['changes']) || record['changes'].length === 0) return 'changes must be a non-empty list of {"path", "value"}';
  const changes: FieldChange[] = [];
  for (const entry of record['changes'] as unknown[]) {
    const change = entry as { path?: unknown; value?: unknown } | null;
    if (typeof change !== 'object' || change === null || typeof change.path !== 'string' || !PATH.test(change.path) || !('value' in change)) return 'each change is {"path": "a.dotted.key", "value": ...}';
    changes.push({ path: change.path, value: change.value as FieldValue });
  }
  return { kind: 'changes', changes, hash: record['hash'], force };
}

/** A change to a key the schema does not name: text or a list of text, the way the Other group edits it; under a map field (a gate) text only. */
function checkUnknown(change: FieldChange): string | null {
  const { value } = change;
  if (value === null || typeof value === 'string') return null;
  if (fieldCovering(change.path) === undefined && Array.isArray(value) && value.every((entry) => typeof entry === 'string')) return null;
  return `${change.path} is not a key the console knows: send text${fieldCovering(change.path) === undefined ? ' or a list of text' : ''}`;
}

/**
 * Reads and writes one project's `.flow/config.yaml`. A write is refused when the file changed
 * on disk since it was read (the hash), and when git has uncommitted changes in it unless the
 * request says `force`: the file is tracked, and the console must not mix its edit into someone's
 * work in progress. The text is rewritten in place, comments and order kept.
 */
export class FlowConfigEditor {
  private readonly deps: FlowConfigEditorDependencies;
  readonly file: string;
  /** Saves run one at a time: each waits for the one before it has written. */
  private queue: Promise<unknown> = Promise.resolve();

  constructor(dependencies: FlowConfigEditorDependencies) {
    this.deps = dependencies;
    this.file = path.join(dependencies.root, CONFIG_FILE);
  }

  async read(): Promise<EditorReply> {
    const text = await this.text();
    if (text === null) return { status: HTTP_NOT_FOUND, body: { error: `${this.file} is missing` } };
    return { status: HTTP_OK, body: describe(this.file, text, await this.hostDefaults()) };
  }

  write(body: unknown): Promise<EditorReply> {
    const turn = this.queue.then(() => this.writeNow(body));
    this.queue = turn.catch(() => {});
    return turn;
  }

  private async writeNow(body: unknown): Promise<EditorReply> {
    const request = readRequest(body);
    if (typeof request === 'string') return { status: HTTP_BAD_REQUEST, body: { error: request } };
    const current = await this.text();
    if (current === null) return { status: HTTP_NOT_FOUND, body: { error: `${this.file} is missing` } };
    const next = request.kind === 'text' ? this.checkText(request.text) : this.edit(current, request.changes);
    if (!next.ok) return { status: HTTP_BAD_REQUEST, body: { error: next.error } };
    if (contentHash(current) !== request.hash) {
      return { status: HTTP_CONFLICT, body: { reason: 'stale', error: `${CONFIG_FILE} changed on disk since it was read; reload it and make the change again` } };
    }
    const git = await this.gitState();
    if (git.dirty !== null && !request.force) return { status: HTTP_CONFLICT, body: { reason: 'dirty', error: git.dirty } };
    const before = parseDocument(current).ok ? parseYaml(current) : {};
    const after = parseYaml(next.text);
    const saved = changedPaths(before, after);
    if (next.text !== current) {
      // The git check can take seconds, and the steward may append to the pool meanwhile: read again just before writing.
      if (contentHash((await this.text()) ?? '') !== request.hash) {
        return { status: HTTP_CONFLICT, body: { reason: 'stale', error: `${CONFIG_FILE} changed on disk while the save was checked; reload it and make the change again` } };
      }
      const written = await this.replace(next.text);
      if (written !== null) return { status: HTTP_BAD_REQUEST, body: { error: written } };
      await this.deps.refresh();
      this.deps.log.info('flow.config.saved', { project: this.deps.projectId, file: this.file, keys: saved.join(','), raw: request.kind === 'text', force: request.force });
    }
    const reply: FlowConfigSaved = { ...describe(this.file, next.text, await this.hostDefaults()), saved, followUps: followUpsOf(saved, after), notes: git.note === null ? [] : [git.note] };
    return { status: HTTP_OK, body: reply };
  }

  /** Read on every GET and save, so a codex default changed since shows without a restart. */
  private hostDefaults(): Promise<HostDefaults> {
    return readHostDefaults(this.deps.home ?? os.homedir());
  }

  private async text(): Promise<string | null> {
    try { return await readFile(this.file, 'utf8'); } catch { return null; }
  }

  /** Raw YAML: the whole file, accepted only when it is in the flat format and every known key fits its type. */
  private checkText(text: string): { ok: true; text: string } | { ok: false; error: string } {
    const parsed = parseDocument(text);
    if (!parsed.ok) return { ok: false, error: `not saved, the text is not in the flat format: ${parsed.error}` };
    const errors = describe(this.file, text).warnings;
    return errors.length === 0 ? { ok: true, text } : { ok: false, error: errors.join('; ') };
  }

  private edit(current: string, changes: FieldChange[]): { ok: true; text: string } | { ok: false; error: string } {
    const parsed = parseDocument(current);
    if (!parsed.ok) return { ok: false, error: `the file is not in the flat format, so change it in Raw YAML: ${parsed.error}` };
    let text = current;
    for (const change of changes) {
      const spec = fieldAt(change.path);
      if (spec !== undefined) {
        const checked = checkChange(spec, change.value);
        if (!checked.ok) return checked;
      } else {
        const refused = checkUnknown(change);
        if (refused !== null) return { ok: false, error: refused };
      }
      const shape = shapeOf(spec, change.value);
      const edited = applyChange(text, change.path, shape, change.value);
      if (!edited.ok) return { ok: false, error: `${change.path}: ${edited.error}` };
      if (!readsBack(edited.text, change.path, shape, change.value)) return { ok: false, error: `${change.path}: the edit would not read back as written, so nothing was saved` };
      text = edited.text;
    }
    const after = parseDocument(text);
    return after.ok ? { ok: true, text } : { ok: false, error: `the edit left the file out of the flat format: ${after.error}` };
  }

  /**
   * Whether git holds work in the file that a save would mix with: only a tracked file with
   * changes is dirty. An untracked file, or a project that is not a git checkout, has no such
   * work to lose and saves with a note.
   */
  private async gitState(): Promise<{ dirty: string | null; note: string | null }> {
    const result = await this.deps.runner({ command: 'git', args: ['status', '--porcelain', '--', CONFIG_FILE], cwd: this.deps.root, timeoutMs: GIT_TIMEOUT_MS, env: scriptEnvironment() });
    if (result.code !== 0) return { dirty: null, note: `git could not read the project (${result.stderr.trim().split('\n')[0] || 'no answer'}), so nothing tells whether ${CONFIG_FILE} holds uncommitted work` };
    const status = result.stdout.trim();
    if (status === '') return { dirty: null, note: null };
    if (status.startsWith('??')) return { dirty: null, note: `${CONFIG_FILE} is not tracked by git: add and commit it to keep the change` };
    return { dirty: `${CONFIG_FILE} has uncommitted changes in git; commit or discard them there first, or save anyway to write over them`, note: null };
  }

  /** Writes the new text whole: a temp file beside it with the old file's mode, renamed over it. Returns why it failed, or null. */
  private async replace(text: string): Promise<string | null> {
    const temporary = path.join(path.dirname(this.file), `.config.yaml.${process.pid}.tmp`);
    try {
      const { mode } = await stat(this.file);
      await writeFile(temporary, text);
      await chmod(temporary, mode & 0o7777);
      await rename(temporary, this.file);
      return null;
    } catch (error) {
      await rm(temporary, { force: true });
      return `could not write ${this.file}: ${error instanceof Error ? error.message : String(error)}`;
    }
  }
}
