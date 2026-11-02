import { useCallback, useEffect, useState } from 'react';
import type { FieldChange, FieldGroup, FieldSpec, FieldValue, FlowConfigDocument, FlowConfigSaved, HostDefaults, JobsHost, Section } from '../../../daemon/src/plugins/flow/schema.ts';
import { checkSchedule, DEFAULT_JOBS_HOST, fieldAt, legacyJobsSetting, legacyReadySetting, OTHER_GROUP, plainListValue } from '../../../daemon/src/plugins/flow/schema.ts';
import { projectPath, unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { OpenFileButton } from '../OpenFileButton.tsx';
import { ActionButton, ActionsProvider, Empty, Module } from '../ui.tsx';
import { useActions } from '../useActions.ts';
import { HTTP_OK } from '../useProject.ts';
import { ChecklistControl, KeysControl, mapEntries, RowsControl, rowsProblem, ScheduleControl, WorkersControl } from './FlowFieldControls.tsx';

export const FLOW_CONFIG_PATH = '/plugins/flow/config';
export const TRACKED_NOTE = 'This edits .flow/config.yaml in the project. It is a tracked file: commit it there.';
const HTTP_CONFLICT = 409;
/** The select option that leaves a key out of the file. */
const UNSET = '';
/** The label of the empty option of a host's model or effort: the host picks. */
export const HOST_DEFAULT = 'host default';
/** The select option of a known-or-free-text value that opens the text field. */
export const OTHER = 'other…';
const OTHER_VALUE = '\u0000other';

/** Which part of a project's flow settings shows: every group, one group, the raw file, or nothing (the drafts stay). */
export type FlowShown = 'all' | FieldGroup | 'raw' | null;

type Read = { kind: 'loading' } | { kind: 'read'; document: FlowConfigDocument } | { kind: 'unreachable'; message: string };
/** What the last save of the form, or of Raw YAML, led to. */
type Result = { kind: 'saved'; saved: FlowConfigSaved } | { kind: 'refused'; message: string; reason: 'dirty' | 'stale' | null; body: unknown };

/**
 * One project's .flow/config.yaml as a form grouped like the schema, with Raw YAML after it. The
 * form keeps its edits while another part shows, and one save bar sends every edit at once.
 */
export function FlowSettings({ projectId, name, show = 'all' }: { projectId: string; name: string; show?: FlowShown }) {
  const { api } = useServices();
  const actions = useActions(projectId);
  const [read, setRead] = useState<Read>({ kind: 'loading' });
  const path = projectPath(projectId, FLOW_CONFIG_PATH);

  const load = useCallback(async (): Promise<void> => {
    const response = await api.request(path, 'GET', null);
    setRead(response.status === HTTP_OK && response.body !== null ? { kind: 'read', document: response.body as FlowConfigDocument } : { kind: 'unreachable', message: errorOf(response.body) ?? unreachableMessage(response.status) });
  }, [api, path]);
  useEffect(() => { void load(); }, [load]);

  /** Sends one save; a success replaces the document, so the next save carries the new hash. */
  const save = useCallback(async (body: Record<string, unknown>): Promise<Result> => {
    const response = await api.request(path, 'PUT', body);
    if (response.status === HTTP_OK && response.body !== null) {
      const saved = response.body as FlowConfigSaved;
      setRead({ kind: 'read', document: saved });
      return { kind: 'saved', saved };
    }
    const reason = (response.body as { reason?: unknown } | null)?.reason;
    return { kind: 'refused', message: errorOf(response.body) ?? unreachableMessage(response.status), reason: response.status === HTTP_CONFLICT && (reason === 'dirty' || reason === 'stale') ? reason : null, body };
  }, [api, path]);

  const title = show === 'all' || show === null ? `flow settings for ${name}` : show === 'raw' ? `${name}: raw YAML` : show;
  const aside = show === 'all' ? null : <span className="muted">{name} · .flow/config.yaml</span>;
  if (show === null && read.kind !== 'read') return null;
  if (read.kind === 'loading') return <Module className="flow-settings" title={title} aside={aside} footer={null}><Empty>Reading .flow/config.yaml…</Empty></Module>;
  if (read.kind === 'unreachable') return <Module className="flow-settings" title={title} aside={aside} footer={null}><Empty>{read.message}.</Empty></Module>;
  const { document } = read;
  // Hidden, not unmounted, while another part of the page shows: the form's edits wait for the save.
  return (
    <ActionsProvider actions={actions}>
      <div className="flow-settings-part" hidden={show === null}>
        <Module className="flow-settings" title={title} aside={aside} footer={null}>
          {show !== 'raw' && <p className="module-help flow-note">{TRACKED_NOTE}</p>}
          {document.warnings.length > 0 && (
            <ul className="flow-warnings" aria-label={`Warnings for ${name}`}>{document.warnings.map((warning) => <li key={warning} className="tone-failing">{warning}</li>)}</ul>
          )}
          {document.values !== null && <FlowForm projectId={projectId} document={document} name={name} show={show} save={save} reload={load} />}
          {(show === 'all' || show === 'raw') && <RawYaml key={document.hash} name={name} document={document} open={show === 'raw' || document.values === null} save={save} reload={load} />}
        </Module>
      </div>
    </ActionsProvider>
  );
}

type FormProps = { projectId: string; document: FlowConfigDocument; name: string; show: FlowShown; save: (body: Record<string, unknown>) => Promise<Result>; reload: () => Promise<void> };

/**
 * Every group's fields in one form, and one save bar that sends only what changed. Both hosts'
 * model and effort show, since workers and schedules run on either host whatever `jobs.host`
 * says. A save of either half of a host's pair sends both, so the host's map is written whole;
 * while that map is absent and a deprecated key is set, the pair starts at what the plugin really
 * runs with, so the fallback ends with the same values. A deprecated key shows only when the file
 * sets it, with a Clear that saves it as null at once. The groups the page does not show stay
 * mounted but hidden, so their edits wait for the save.
 */
function FlowForm({ projectId, document, name, show, save, reload }: FormProps) {
  const values = document.values!;
  const fields = document.sections.flatMap((section) => section.fields);
  const initial = Object.fromEntries(fields.map((spec) => [spec.path, legacyOf(spec, values)?.value ?? textOf(spec, fileValueOf(spec, values))]));
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  /** What the last save sent, so Save anyway sends the same again with force. */
  const [sent, setSent] = useState<{ changes: FieldChange[]; only: string | null }>({ changes: [], only: null });
  const shown = fields.filter((spec) => spec.deprecated === undefined || isSet(valueAt(values, spec.path)));
  const changed = (spec: FieldSpec): boolean => spec.deprecated === undefined && drafts[spec.path] !== undefined && drafts[spec.path] !== initial[spec.path];
  const pairChanged = (host: JobsHost): boolean => shown.some((spec) => spec.host?.host === host && changed(spec));
  const edited = shown.filter((spec) => changed(spec) || (spec.host !== undefined && pairChanged(spec.host.host)));
  const parsed = edited.map((spec) => ({ spec, parsed: valueOf(spec, drafts[spec.path] ?? initial[spec.path] ?? '') }));
  const invalid = parsed.find((entry) => !entry.parsed.ok);
  /** `only`: the one key a Clear saves, whose draft alone goes after it; the other edits stay. */
  const submit = async (changes: FieldChange[], force: boolean, only: string | null = null): Promise<void> => {
    setBusy(true);
    setSent({ changes, only });
    const outcome = await save({ changes, hash: document.hash, ...(force ? { force: true } : {}) });
    setBusy(false);
    setResult(outcome);
    if (outcome.kind !== 'saved') return;
    if (only === null) setDrafts({});
    else setDrafts((current) => Object.fromEntries(Object.entries(current).filter(([key]) => key !== only)));
  };
  const editedChanges = (): FieldChange[] => parsed.flatMap(({ spec, parsed: entry }) => (entry.ok ? [{ path: spec.path, value: entry.value }] : []));
  const groupShows = (group: FieldGroup): boolean => show === 'all' || show === group || (show === 'raw' && group === OTHER_GROUP);
  const groups = new Set(edited.map((spec) => spec.group));
  const current = (path: string): string => drafts[path] ?? initial[path] ?? '';
  const context: FormContext = {
    idPrefix: `flow-${projectId}-`,
    usesGithub: trackers(current).includes('github'),
    jobsHost: current('jobs.host') || DEFAULT_JOBS_HOST,
    workersSplit: current('jobs.workers').trim() !== '',
    picks: pickNames(values),
  };
  return (
    <form className={show === 'all' ? 'flow-form' : 'flow-form single'} aria-label={`flow settings form for ${name}`} onSubmit={(event) => { event.preventDefault(); void submit(editedChanges(), false); }}>
      {document.sections.map((section) => (
        <GroupFields key={section.group} section={section} hidden={!groupShows(section.group)} shown={shown} values={values} hostDefaults={document.hostDefaults} busy={busy} drafts={drafts} initial={initial} context={context}
          edit={(path, text) => { setDrafts((current) => ({ ...current, [path]: text })); setResult(null); }}
          clear={(path) => { void submit([{ path, value: null }], false, path); }} />
      ))}
      {show !== null && (show !== 'raw' || document.sections.some((section) => section.group === OTHER_GROUP)) && (
        <div className={edited.length > 0 ? 'flow-savebar pending' : 'flow-savebar'} role="region" aria-label={`Save for ${name}`}>
          <span className="flow-pending" role="status">
            {edited.length === 0 ? 'No unsaved changes.' : `${edited.length} unsaved ${edited.length === 1 ? 'change' : 'changes'} in ${[...groups].join(', ')}.`}
          </span>
          {invalid !== undefined && !invalid.parsed.ok && <span className="muted" role="status">{invalid.spec.label} needs {invalid.parsed.error}</span>}
          <SaveResult result={result} retry={() => { void submit(sent.changes, true, sent.only); }} reload={reload} />
          <span className="flow-savebar-buttons">
            <button type="button" className="button" disabled={busy || edited.length === 0} onClick={() => { setDrafts({}); setResult(null); }}>Discard</button>
            <button type="submit" className="button primary" disabled={busy || edited.length === 0 || invalid !== undefined}>{busy ? 'Saving…' : 'Save changes'}</button>
          </span>
        </div>
      )}
    </form>
  );
}

/** What a field's control needs from the rest of the form, as edited so far. */
type FormContext = {
  /** What every control's id starts with: the project's own, since every project's form stays mounted on the page. */
  idPrefix: string;
  /** Whether a tracker of the project is GitHub: the fields only the GitHub adapter reads show only then. */
  usesGithub: boolean;
  /** jobs.host, the host of a schedule that names none. */
  jobsHost: string;
  /** Whether jobs.workers splits the next job's workers across hosts. */
  workersSplit: boolean;
  /** The pick filters the file names, which a next schedule may run through (--pick). */
  picks: string[];
};

/** The names under `pick` in the parsed file, in file order. */
function pickNames(values: Record<string, unknown>): string[] {
  const picks = values['pick'];
  return picks !== null && typeof picks === 'object' && !Array.isArray(picks) ? Object.keys(picks) : [];
}

/** The trackers the flow reads, from the form's text: `trackers` when it names some, else the default (local when unset) and each kind's own. */
function trackers(current: (path: string) => string): string[] {
  const named = current('trackers').split('\n').map((line) => line.trim()).filter((tracker) => tracker !== '');
  if (named.length > 0) return named;
  return [current('adapters.default') || 'local', ...['epic', 'task', 'bug'].map((kind) => current(`adapters.${kind}`))].filter((tracker) => tracker !== '');
}

/** What shows instead of the fields only the GitHub adapter reads, while no tracker is GitHub. */
export const NO_GITHUB = 'No tracker here uses GitHub, so these settings do nothing and are hidden. Pick github as a tracker to set them.';

type GroupProps = {
  section: Section; hidden: boolean; shown: FieldSpec[]; values: Record<string, unknown>; hostDefaults: HostDefaults; busy: boolean;
  drafts: Record<string, string>; initial: Record<string, string>; context: FormContext; edit: (path: string, text: string) => void; clear: (path: string) => void;
};

/**
 * One group (a page of the settings), in its parts when its fields name some, each part under its
 * own small heading, every field in schema order. A key the file leaves out (with no deprecated key
 * standing in for it) is marked default beside its name; the mark follows the file, not the draft,
 * so it stays put while the field is edited. The fields only the GitHub adapter reads give way to
 * one line while no tracker is GitHub.
 */
function GroupFields({ section, hidden, shown, values, hostDefaults, busy, drafts, initial, context, edit, clear }: GroupProps) {
  const fields = section.fields.filter((spec) => shown.includes(spec));
  const inFile = (spec: FieldSpec): boolean => isSet(fileValueOf(spec, values)) || legacyOf(spec, values) !== null;
  const control = (spec: FieldSpec) => (spec.deprecated !== undefined
    ? <DeprecatedField key={spec.path} id={`${context.idPrefix}${spec.path}`} spec={spec} fileValue={valueAt(values, spec.path)} busy={busy} clear={() => clear(spec.path)} />
    : <FieldControl key={spec.path} spec={spec} fileValue={fileValueOf(spec, values)} legacy={legacyOf(spec, values)} unset={!inFile(spec)} hostDefaults={hostDefaults} context={context} text={drafts[spec.path] ?? initial[spec.path] ?? ''} onChange={(text) => edit(spec.path, text)} />);
  const parts = [...new Set(fields.map((spec) => spec.part ?? ''))];
  const partFields = (part: string) => {
    const inPart = fields.filter((spec) => (spec.part ?? '') === part);
    const hiddenHere = !context.usesGithub && inPart.some((spec) => spec.adapter === 'github');
    const showing = hiddenHere ? inPart.filter((spec) => spec.adapter === undefined) : inPart;
    return (
      <>
        {hiddenHere && <p className="module-help flow-no-tracker">{NO_GITHUB}</p>}
        {showing.length > 0 && <div className="flow-fields">{showing.map(control)}</div>}
      </>
    );
  };
  return (
    <fieldset className="flow-group" hidden={hidden} aria-label={section.group}>
      <legend className="group-head">{section.group}</legend>
      {parts.map((part) => (part === ''
        ? <div key="" className="flow-part">{partFields(part)}</div>
        : <section key={part} className="flow-part" aria-label={part}><h3 className="flow-part-head">{part}</h3>{partFields(part)}</section>))}
    </fieldset>
  );
}

function errorOf(body: unknown): string | null {
  const error = (body as { error?: unknown } | null)?.error;
  return typeof error === 'string' && error !== '' ? error : null;
}

/** The value at a dotted path of the parsed file, or undefined. */
export function valueAt(values: Record<string, unknown>, path: string): unknown {
  let current: unknown = values;
  for (const key of path.split('.')) {
    if (current === null || typeof current !== 'object' || Array.isArray(current)) return undefined;
    current = (current as Record<string, unknown>)[key];
  }
  return current;
}

/** A field's value in the file: its own key's, else the plain list it stands for (`reviews.reviewers` as the default reviewers). */
function fileValueOf(spec: FieldSpec, values: Record<string, unknown>): unknown {
  return valueAt(values, spec.path) ?? plainListValue(values, spec);
}

/** A map whose entries are maps themselves (a gate with command and paths) is edited only in Raw YAML. */
function nested(value: unknown): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.values(value).some((entry) => typeof entry !== 'string');
}

/** The text a control starts with, from the file's value. */
export function textOf(spec: FieldSpec, value: unknown): string {
  if (value === undefined || value === null) return '';
  // A bare list key reads as an empty map.
  if (spec.type === 'list') return Array.isArray(value) ? value.map(String).join('\n') : typeof value === 'string' ? value : '';
  if (spec.type === 'map') return typeof value === 'object' ? Object.entries(value as Record<string, unknown>).map(([key, entry]) => `${key}: ${String(entry)}`).join('\n') : String(value);
  return String(value);
}

/** The value a control's text stands for, as the daemon takes it, or why it is not one. */
export function valueOf(spec: FieldSpec, text: string): { ok: true; value: FieldValue } | { ok: false; error: string } {
  switch (spec.type) {
    case 'number': {
      if (text.trim() === '') return { ok: true, value: null };
      const number = Number(text);
      return Number.isInteger(number) ? { ok: true, value: number } : { ok: false, error: 'a whole number' };
    }
    case 'boolean': return { ok: true, value: text === UNSET ? null : text === 'true' };
    // A host's own model or effort is always written, empty for the host's default: a present
    // jobs.<host> map is what stops the plugin falling back to the deprecated jobs.model.
    case 'enum': case 'enumOrText': return { ok: true, value: spec.host !== undefined ? text.trim() : text === UNSET ? null : text };
    case 'list': {
      const items = text.split('\n').map((line) => line.trim()).filter((line) => line !== '');
      const other = spec.values === undefined ? undefined : items.find((item) => !spec.values!.includes(item));
      return other === undefined ? { ok: true, value: items } : { ok: false, error: `only ${spec.values!.join(' and ')}, not ${other}` };
    }
    case 'map': return mapValueOf(spec, text);
    case 'schedule': {
      if (text.trim() === '') return { ok: true, value: text };
      const checked = checkSchedule(text);
      return checked.ok ? { ok: true, value: text } : { ok: false, error: `a schedule flow can read (${checked.error})` };
    }
    case 'string': case 'duration': return { ok: true, value: text };
  }
}

/**
 * A map's text as the daemon takes it. Rows need a name each; a map under fixed names takes only
 * those, and with none filled it leaves the key out; the workers per host are counts from 1, and
 * with no host on the key is left out too.
 */
function mapValueOf(spec: FieldSpec, text: string): { ok: true; value: FieldValue } | { ok: false; error: string } {
  if (spec.rows !== undefined) {
    const problem = rowsProblem(spec, mapEntries(text).map(([name, value]) => ({ name, value })));
    if (problem !== null) return { ok: false, error: problem.charAt(0).toLowerCase() + problem.slice(1).replace(/\.$/, '') };
  }
  const entries: Record<string, string> = {};
  for (const line of text.split('\n').map((entry) => entry.trim()).filter((entry) => entry !== '')) {
    const colon = line.indexOf(':');
    if (colon <= 0) return { ok: false, error: `"${line}" is not name: value` };
    entries[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
  }
  const names = Object.keys(entries);
  if (spec.keys !== undefined) {
    const known = spec.keys.map((key) => key.name);
    const other = names.find((name) => !known.includes(name));
    if (other !== undefined) return { ok: false, error: `only ${known.join(', ')}: remove ${other}` };
    return { ok: true, value: names.length === 0 ? null : entries };
  }
  if (spec.counts !== undefined) {
    const max = spec.max ?? Number.MAX_SAFE_INTEGER;
    const bad = names.find((name) => !/^[0-9]+$/.test(entries[name]!) || Number(entries[name]) > max);
    if (bad !== undefined) return { ok: false, error: `a whole number of ${bad} workers up to ${max}` };
    return { ok: true, value: names.length === 0 ? null : entries };
  }
  return { ok: true, value: entries };
}

/** Whether the file sets a key: a deprecated one shows only then (an empty value is the same as none to the flow). */
function isSet(value: unknown): boolean {
  return value !== undefined && value !== null && value !== '';
}

/**
 * What the plugin runs a key with while the file leaves it to a deprecated one: a host's model or
 * effort while its jobs.<host> map is absent, a readiness key while it is unset. The value as the
 * form's text, or null.
 */
function legacyOf(spec: FieldSpec, values: Record<string, unknown>): { value: string; from: string } | null {
  if (spec.host !== undefined) return legacyJobsSetting(values, spec.host.host, spec.host.setting);
  const ready = legacyReadySetting(values, spec.path);
  return ready === null ? null : { value: ready.value.join('\n'), from: ready.from };
}

/** A deprecated key: its value read-only, the note, and Clear. */
function DeprecatedField({ id, spec, fileValue, busy, clear }: { id: string; spec: FieldSpec; fileValue: unknown; busy: boolean; clear: () => void }) {
  return (
    <div className="flow-field">
      <FieldLabel spec={spec} id={id} />
      <span className="flow-deprecated">
        <input id={id} className="input mono" type="text" value={String(fileValue)} readOnly />
        <button type="button" className="button" aria-label={`Clear ${spec.label}`} disabled={busy} onClick={clear}>Clear</button>
      </span>
      <p className="module-help flow-help">{spec.deprecated}</p>
    </div>
  );
}

/** The help under a host's model or effort: the schema's sentence, then what the host's default is on this machine when the daemon could read it. */
export function hostDefaultHelp(spec: FieldSpec, hostDefaults: HostDefaults): string {
  if (spec.host?.host !== 'codex') return '';
  const codex = hostDefaults.codex;
  if (codex === null) return ' This machine has no ~/.codex/config.toml, so Codex picks its built-in default.';
  const value = spec.host.setting === 'model' ? codex.model : codex.effort;
  const key = spec.host.setting === 'model' ? 'model' : 'model_reasoning_effort';
  return value === null ? ` ~/.codex/config.toml sets no ${key}, so Codex picks its built-in default.` : ` On this machine that is ${value} (${key}${codex.profile === null ? '' : ` of profile ${codex.profile}`} in ~/.codex/config.toml).`;
}

type FieldProps = { spec: FieldSpec; fileValue: unknown; legacy: { value: string; from: string } | null; unset: boolean; hostDefaults: HostDefaults; context: FormContext; text: string; onChange: (text: string) => void };

function FieldControl({ spec, fileValue, legacy, unset, hostDefaults, context, text, onChange }: FieldProps) {
  const id = `${context.idPrefix}${spec.path}`;
  const labelId = `${id}-label`;
  const grouped = { spec, labelId, text, onChange };
  /** A control of several boxes is a group its label names, and the help says nothing of the text behind it. */
  let group = true;
  const known = spec.values ?? [];
  // A value not in the list opens the text field; so does picking "other…", until a listed value is picked.
  const [other, setOther] = useState(spec.type === 'enumOrText' && text !== '' && !known.includes(text));
  let control;
  if (spec.type === 'map' && nested(fileValue)) {
    control = <p className="muted" id={id} aria-labelledby={labelId}>Holds entries with lines under them (such as command and paths): change it in Raw YAML.</p>;
  } else if (spec.type === 'map' && spec.counts !== undefined) {
    control = <WorkersControl {...grouped} />;
  } else if (spec.type === 'map' && spec.keys !== undefined) {
    control = <KeysControl {...grouped} />;
  } else if (spec.type === 'map' && spec.rows !== undefined) {
    control = <RowsControl {...grouped} />;
  } else if (spec.type === 'list' && spec.values !== undefined) {
    control = <ChecklistControl {...grouped} />;
  } else if (spec.type === 'schedule') {
    control = <ScheduleControl {...grouped} jobsHost={context.jobsHost} workersSplit={context.workersSplit} picks={context.picks} />;
  } else if (spec.type === 'boolean' || spec.type === 'enum') {
    const options = spec.type === 'boolean' ? ['true', 'false'] : spec.values ?? [];
    group = false;
    control = (
      <select id={id} className="input" value={text} onChange={(event) => onChange(event.target.value)}>
        <option value={UNSET}>{spec.host !== undefined ? HOST_DEFAULT : '(not set)'}</option>
        {options.map((option) => <option key={option} value={option}>{option}</option>)}
      </select>
    );
  } else if (spec.type === 'enumOrText') {
    group = false;
    control = (
      <>
        <select id={id} className="input" value={other ? OTHER_VALUE : text} onChange={(event) => {
          const picked = event.target.value;
          if (picked === OTHER_VALUE) { setOther(true); return; }
          setOther(false);
          onChange(picked);
        }}>
          <option value={UNSET}>{spec.host !== undefined ? HOST_DEFAULT : '(not set)'}</option>
          {known.map((option) => <option key={option} value={option}>{option}</option>)}
          <option value={OTHER_VALUE}>{OTHER}</option>
        </select>
        {other && <input className="input mono" aria-label={`${spec.label}, other`} type="text" value={text} placeholder="any name the CLI takes" onChange={(event) => onChange(event.target.value)} />}
      </>
    );
  } else if (spec.type === 'list' || spec.type === 'map') {
    group = false;
    const example = spec.placeholder ?? (spec.type === 'list' ? 'one per line' : 'name: value, one per line');
    control = <textarea id={id} className="input mono" rows={Math.max(2, text.split('\n').length, example.split('\n').length)} value={text} placeholder={example} onChange={(event) => onChange(event.target.value)} />;
  } else {
    group = false;
    control = <input id={id} className="input mono" type={spec.type === 'number' ? 'number' : 'text'} value={text} placeholder={spec.placeholder} onChange={(event) => onChange(event.target.value)} />;
  }
  return (
    <div className={spec.type === 'schedule' || spec.rows !== undefined ? 'flow-field flow-wide' : 'flow-field'}>
      <FieldLabel spec={spec} id={id} group={group} unset={unset} />
      {control}
      {legacy !== null && <p className="module-help flow-help flow-legacy">now {legacy.value.split('\n').join(', ')}, from the deprecated {legacy.from}</p>}
      <p className="module-help flow-help">{spec.help}{hostDefaultHelp(spec, hostDefaults)}{group ? '' : spec.type === 'list' ? ' One per line.' : spec.type === 'map' ? ' One name: value per line.' : ''}</p>
    </div>
  );
}

/**
 * A key's plain name, with the path the file writes it under beside it, and "default" when the file
 * leaves the key out. A control of several boxes (a group) is named by it through aria-labelledby,
 * so the name is no <label> of one box.
 */
function FieldLabel({ spec, id, group = false, unset = false }: { spec: FieldSpec; id: string; group?: boolean; unset?: boolean }) {
  const name = group ? <span id={`${id}-label`} className="flow-label-name">{spec.label}</span> : <label id={`${id}-label`} htmlFor={id}>{spec.label}</label>;
  return (
    <span className="flow-label">
      {name}
      {spec.label !== spec.path && <span className="mono flow-key">{spec.path}</span>}
      {unset && <span className="flow-default" title="The file leaves this out, so the flow uses its default.">default</span>}
    </span>
  );
}

/** What a save led to: the keys saved and their follow-ups (with the button that runs one), or the refusal and the way past it. */
function SaveResult({ result, retry, reload }: { result: Result | null; retry: () => void; reload: () => Promise<void> }) {
  if (result === null) return null;
  if (result.kind === 'refused') {
    return (
      <span className="flow-result" role="alert">
        <span className="tone-failing">Not saved: {result.message}</span>
        {result.reason === 'dirty' && <button type="button" className="button" onClick={retry}>Save anyway</button>}
        {result.reason === 'stale' && <button type="button" className="button" onClick={() => { void reload(); }}>Reload</button>}
      </span>
    );
  }
  const { saved } = result;
  return (
    <span className="flow-result" role="status">
      <span>{saved.saved.length === 0 ? 'Nothing changed.' : `Saved ${saved.saved.map((path) => fieldAt(path)?.label ?? path).join(', ')}.`}</span>
      {saved.notes.map((note) => <span key={note} className="muted">{note}.</span>)}
      {saved.followUps.map((followUp) => (
        <span key={followUp.note} className="flow-follow-up">
          {followUp.note}
          {followUp.action !== null && <ActionButton kind={followUp.action.kind} args={followUp.action.args} label={followUp.action.label} primary />}
        </span>
      ))}
    </span>
  );
}

/** The whole file as text, folded away; saved with the same checks as the form. */
function RawYaml({ name, document, open, save, reload }: { name: string; document: FlowConfigDocument; open: boolean; save: (body: Record<string, unknown>) => Promise<Result>; reload: () => Promise<void> }) {
  const [text, setText] = useState(document.text);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  const submit = async (force: boolean): Promise<void> => {
    setBusy(true);
    const outcome = await save({ text, hash: document.hash, ...(force ? { force: true } : {}) });
    setBusy(false);
    setResult(outcome);
  };
  return (
    <details className="flow-raw" open={open}>
      <summary>Raw YAML</summary>
      <form onSubmit={(event) => { event.preventDefault(); void submit(false); }}>
        <textarea className="input mono" aria-label={`Raw YAML for ${name}`} rows={Math.min(40, text.split('\n').length + 1)} value={text} onChange={(event) => { setText(event.target.value); setResult(null); }} />
        <div className="flow-save">
          <button type="submit" className="button primary" disabled={busy || text === document.text}>{busy ? 'Saving…' : 'Save YAML'}</button>
          <OpenFileButton path={document.path} with="editor" label="Open" />
          <SaveResult result={result} retry={() => { void submit(true); }} reload={reload} />
        </div>
      </form>
    </details>
  );
}
