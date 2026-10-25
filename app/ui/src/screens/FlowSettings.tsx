import { useCallback, useEffect, useState } from 'react';
import type { FieldSpec, FieldValue, FlowConfigDocument, FlowConfigSaved, Section } from '../../../daemon/src/plugins/flow/schema.ts';
import { projectPath, unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { ActionButton, ActionsProvider, Empty, Module } from '../ui.tsx';
import { useActions } from '../useActions.ts';
import { HTTP_OK } from '../useProject.ts';
import type { ProjectSummary } from '../stream.ts';

export const FLOW_CONFIG_PATH = '/plugins/flow/config';
export const TRACKED_NOTE = 'This edits .flow/config.yaml in the project. It is a tracked file: commit it there.';
const HTTP_CONFLICT = 409;
/** The select option that leaves a key out of the file. */
const UNSET = '';

/** The flow settings of every project the daemon watches, one section each. */
export function FlowSettingsList() {
  const { api } = useServices();
  const [projects, setProjects] = useState<ProjectSummary[] | null>(null);
  useEffect(() => {
    let cancelled = false;
    void api.request('/api/projects', 'GET', null).then((response) => {
      if (!cancelled && response.status === HTTP_OK && Array.isArray(response.body)) setProjects(response.body as ProjectSummary[]);
    });
    return () => { cancelled = true; };
  }, [api]);
  if (projects === null) return null;
  return <>{projects.map((project) => <FlowSettings key={project.id} projectId={project.id} name={project.name} />)}</>;
}

type Read = { kind: 'loading' } | { kind: 'read'; document: FlowConfigDocument } | { kind: 'unreachable'; message: string };
/** What the last save of one part (a group, or Raw YAML) led to. */
type Result = { kind: 'saved'; saved: FlowConfigSaved } | { kind: 'refused'; message: string; reason: 'dirty' | 'stale' | null; body: unknown };

/** One project's .flow/config.yaml as a form grouped like the schema, with Raw YAML at the bottom. */
export function FlowSettings({ projectId, name }: { projectId: string; name: string }) {
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

  const title = `flow settings for ${name}`;
  if (read.kind === 'loading') return <Module className="flow-settings" title={title} aside={null} footer={null}><Empty>Reading .flow/config.yaml…</Empty></Module>;
  if (read.kind === 'unreachable') return <Module className="flow-settings" title={title} aside={null} footer={null}><Empty>{read.message}.</Empty></Module>;
  const { document } = read;
  return (
    <ActionsProvider actions={actions}>
      <Module className="flow-settings" title={title} aside={null} footer={<span className="muted">Saved in <span className="mono">{document.path}</span></span>}>
        <p className="module-help flow-note">{TRACKED_NOTE}</p>
        {document.warnings.length > 0 && (
          <ul className="flow-warnings" aria-label={`Warnings for ${name}`}>{document.warnings.map((warning) => <li key={warning} className="tone-failing">{warning}</li>)}</ul>
        )}
        {document.values !== null && document.sections.map((section) => (
          <GroupForm key={section.group} section={section} values={document.values!} hash={document.hash} save={save} reload={load} />
        ))}
        <RawYaml key={document.hash} name={name} document={document} save={save} reload={load} />
      </Module>
    </ActionsProvider>
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

/** A map whose entries are maps themselves (a gate with command and paths) is edited only in Raw YAML. */
function nested(value: unknown): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.values(value).some((entry) => typeof entry !== 'string');
}

/** The text a control starts with, from the file's value. */
export function textOf(spec: FieldSpec, value: unknown): string {
  if (value === undefined || value === null) return '';
  if (spec.type === 'list') return (Array.isArray(value) ? value : [value]).map(String).join('\n');
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
    case 'enum': return { ok: true, value: text === UNSET ? null : text };
    case 'list': return { ok: true, value: text.split('\n').map((line) => line.trim()).filter((line) => line !== '') };
    case 'map': {
      const entries: Record<string, string> = {};
      for (const line of text.split('\n').map((entry) => entry.trim()).filter((entry) => entry !== '')) {
        const colon = line.indexOf(':');
        if (colon <= 0) return { ok: false, error: `"${line}" is not name: value` };
        entries[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
      }
      return { ok: true, value: entries };
    }
    case 'string': case 'duration': case 'schedule': return { ok: true, value: text };
  }
}

type GroupProps = { section: Section; values: Record<string, unknown>; hash: string; save: (body: Record<string, unknown>) => Promise<Result>; reload: () => Promise<void> };

/** One group of the schema: its fields, and a Save that sends only what changed in it. */
function GroupForm({ section, values, hash, save, reload }: GroupProps) {
  const initial = Object.fromEntries(section.fields.map((spec) => [spec.path, textOf(spec, valueAt(values, spec.path))]));
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  const edited = section.fields.filter((spec) => drafts[spec.path] !== undefined && drafts[spec.path] !== initial[spec.path]);
  const parsed = edited.map((spec) => ({ spec, parsed: valueOf(spec, drafts[spec.path]!) }));
  const invalid = parsed.find((entry) => !entry.parsed.ok);
  const submit = async (force: boolean): Promise<void> => {
    const changes = parsed.flatMap(({ spec, parsed: entry }) => (entry.ok ? [{ path: spec.path, value: entry.value }] : []));
    setBusy(true);
    const outcome = await save({ changes, hash, ...(force ? { force: true } : {}) });
    setBusy(false);
    setResult(outcome);
    if (outcome.kind === 'saved') setDrafts({});
  };
  return (
    <form className="flow-group" aria-label={section.group} onSubmit={(event) => { event.preventDefault(); void submit(false); }}>
      <h3 className="group-head">{section.group}</h3>
      <div className="flow-fields">
        {section.fields.map((spec) => (
          <FieldControl key={spec.path} spec={spec} fileValue={valueAt(values, spec.path)} text={drafts[spec.path] ?? initial[spec.path] ?? ''} onChange={(text) => { setDrafts((current) => ({ ...current, [spec.path]: text })); setResult(null); }} />
        ))}
      </div>
      <div className="flow-save">
        <button type="submit" className="button primary" disabled={busy || edited.length === 0 || invalid !== undefined}>{busy ? 'Saving…' : 'Save'}</button>
        {invalid !== undefined && !invalid.parsed.ok && <span className="muted" role="status">{invalid.spec.path} needs {invalid.parsed.error}</span>}
        <SaveResult result={result} retry={() => { void submit(true); }} reload={reload} />
      </div>
    </form>
  );
}

function FieldControl({ spec, fileValue, text, onChange }: { spec: FieldSpec; fileValue: unknown; text: string; onChange: (text: string) => void }) {
  const id = `flow-${spec.path}`;
  let control;
  if (spec.type === 'map' && nested(fileValue)) {
    control = <p className="muted" id={id}>Holds entries with lines under them (such as command and paths): change it in Raw YAML.</p>;
  } else if (spec.type === 'boolean' || spec.type === 'enum') {
    const options = spec.type === 'boolean' ? ['true', 'false'] : spec.values ?? [];
    control = (
      <select id={id} className="input" aria-label={spec.path} value={text} onChange={(event) => onChange(event.target.value)}>
        <option value={UNSET}>(not set)</option>
        {options.map((option) => <option key={option} value={option}>{option}</option>)}
      </select>
    );
  } else if (spec.type === 'list' || spec.type === 'map') {
    control = <textarea id={id} className="input mono" aria-label={spec.path} rows={Math.max(2, text.split('\n').length)} value={text} placeholder={spec.type === 'list' ? 'one per line' : 'name: value, one per line'} onChange={(event) => onChange(event.target.value)} />;
  } else {
    control = <input id={id} className="input mono" aria-label={spec.path} type={spec.type === 'number' ? 'number' : 'text'} value={text} onChange={(event) => onChange(event.target.value)} />;
  }
  return (
    <div className="flow-field">
      <label className="mono flow-key" htmlFor={id}>{spec.path}</label>
      {control}
      <p className="module-help flow-help">{spec.help}{spec.type === 'list' ? ' One per line.' : spec.type === 'map' ? ' One name: value per line.' : ''}</p>
    </div>
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
      <span>{saved.saved.length === 0 ? 'Nothing changed.' : `Saved ${saved.saved.join(', ')}.`}</span>
      {saved.followUps.map((followUp) => (
        <span key={followUp.note} className="flow-follow-up">
          {followUp.note}
          {followUp.action !== null && <ActionButton kind={followUp.action.kind} args={{}} label={followUp.action.label} primary />}
        </span>
      ))}
    </span>
  );
}

/** The whole file as text, folded away; saved with the same checks as the form. */
function RawYaml({ name, document, save, reload }: { name: string; document: FlowConfigDocument; save: (body: Record<string, unknown>) => Promise<Result>; reload: () => Promise<void> }) {
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
    <details className="flow-raw" open={document.values === null}>
      <summary>Raw YAML</summary>
      <form onSubmit={(event) => { event.preventDefault(); void submit(false); }}>
        <textarea className="input mono" aria-label={`Raw YAML for ${name}`} rows={Math.min(40, text.split('\n').length + 1)} value={text} onChange={(event) => { setText(event.target.value); setResult(null); }} />
        <div className="flow-save">
          <button type="submit" className="button primary" disabled={busy || text === document.text}>{busy ? 'Saving…' : 'Save'}</button>
          <SaveResult result={result} retry={() => { void submit(true); }} reload={reload} />
        </div>
      </form>
    </details>
  );
}
