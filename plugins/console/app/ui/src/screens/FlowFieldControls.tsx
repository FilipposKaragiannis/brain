import { useState } from 'react';
import type { FieldSpec } from '../../../daemon/src/plugins/flow/schema.ts';
import { parseOneLineMap, scheduleJob } from '../../../daemon/src/plugins/flow/schema.ts';
import { scheduleLine, scheduleParts, scheduleProblem, startProblem } from '../jobStart.ts';
import type { ScheduleParts } from '../jobStart.ts';
import { formHost, RunFields, runFormOver, typedModel, WhenFields } from '../scheduleFields.tsx';

/**
 * The controls of the flow settings that hide the shape of the data: a map under fixed names as
 * named boxes, a list of fixed values as checkboxes, a free map as rows, the workers per host as
 * switches, and a schedule as its timing and options. Each still reads and writes the field's
 * draft text (a list one item per line, a map `name: value` per line), so saving stays the same.
 */

/** What every control gets: its field, the id of its label (the control is a group it names), its draft text and the way to change it. */
export type ControlProps = { spec: FieldSpec; labelId: string; text: string; onChange: (text: string) => void };

/**
 * A map's entries in the order the text has them: `name: value` lines, or a map on one line
 * (`{claude: 1, codex: 2}`) as the file may hold it. A value keeps its spaces but the one after
 * the colon, so a box being typed in keeps a trailing space.
 */
export function mapEntries(text: string): [string, string][] {
  const oneLine = parseOneLineMap(text);
  if (oneLine !== null) return Object.entries(oneLine);
  return text.split('\n').filter((line) => line.trim() !== '').map((line) => {
    const colon = line.indexOf(':');
    if (colon < 0) return [line.trim(), ''];
    const rest = line.slice(colon + 1);
    return [line.slice(0, colon).trim(), rest.startsWith(' ') ? rest.slice(1) : rest];
  });
}

export function mapText(entries: [string, string][]): string {
  return entries.map(([name, value]) => `${name}: ${value}`).join('\n');
}

/**
 * State a control keeps beside its draft text, such as a row with nothing in it yet or a time
 * being typed: rebuilt from the text when the text changes from outside (Discard, a save), kept
 * while the changes are the control's own.
 */
function useDraft<T>(text: string, parse: (text: string) => T, onChange: (text: string) => void): [T, (value: T, next: string) => void] {
  const [state, setState] = useState(() => ({ value: parse(text), text }));
  let current = state;
  if (state.text !== text) {
    current = { value: parse(text), text };
    setState(current);
  }
  return [current.value, (value, next) => { setState({ value, text: next }); onChange(next); }];
}

/** A map under fixed names: one labelled box per name, an empty box leaves the name out; a name the flow does not read shows with a Remove. */
export function KeysControl({ spec, labelId, text, onChange }: ControlProps) {
  const keys = spec.keys ?? [];
  const entries = mapEntries(text);
  const names = keys.map((key) => key.name);
  const valueOf = (name: string): string => entries.find(([key]) => key === name)?.[1] ?? '';
  const others = entries.filter(([key]) => !names.includes(key));
  const write = (name: string, value: string): void => {
    const known = keys.map((key): [string, string] => [key.name, key.name === name ? value : valueOf(key.name)]).filter(([, entry]) => entry.trim() !== '');
    onChange(mapText([...known, ...others]));
  };
  return (
    <div className="flow-keys" role="group" aria-labelledby={labelId}>
      {keys.map((key) => (
        <label key={key.name} className="flow-key-box">
          <span>{key.label}</span>
          <input className="input" type="text" value={valueOf(key.name)} placeholder={key.placeholder} onChange={(event) => write(key.name, event.target.value)} />
        </label>
      ))}
      {others.map(([name, value]) => (
        <p key={name} className="module-help flow-help tone-failing">
          The file also sets {name}: {value}, which the flow does not read.{' '}
          <button type="button" className="button" onClick={() => onChange(mapText(entries.filter(([key]) => key !== name)))}>Remove {name}</button>
        </p>
      ))}
    </div>
  );
}

/** A list of fixed values as one checkbox each, in the field's order; a value the flow does not know shows with a Remove. */
export function ChecklistControl({ spec, labelId, text, onChange }: ControlProps) {
  const values = spec.values ?? [];
  const lines = text.split('\n').map((line) => line.trim()).filter((line) => line !== '');
  const others = lines.filter((line) => !values.includes(line));
  const write = (value: string, on: boolean): void => {
    onChange([...values.filter((each) => (each === value ? on : lines.includes(each))), ...others].join('\n'));
  };
  return (
    <div className="flow-checks" role="group" aria-labelledby={labelId}>
      {values.map((value) => (
        <label key={value} className="flow-check">
          <input type="checkbox" checked={lines.includes(value)} onChange={(event) => write(value, event.target.checked)} />
          <span>{value}</span>
        </label>
      ))}
      {others.map((other) => (
        <p key={other} className="module-help flow-help tone-failing">
          The file also lists {other}, which the flow does not know.{' '}
          <button type="button" className="button" onClick={() => onChange(lines.filter((line) => line !== other).join('\n'))}>Remove {other}</button>
        </p>
      ))}
    </div>
  );
}

type Row = { name: string; value: string };
const ROW_NAME = /^[A-Za-z0-9_-]+$/;

/** What is wrong with a free map's rows, or null. */
export function rowsProblem(spec: FieldSpec, rows: Row[]): string | null {
  const words = spec.rows ?? { name: 'Name', value: 'Value' };
  const seen = new Set<string>();
  for (const row of rows) {
    const name = row.name.trim();
    if (name === '' && row.value.trim() === '') continue;
    if (name === '') return `Give the ${words.value.toLowerCase()} ${row.value.trim()} a ${words.name.toLowerCase()} name.`;
    if (!ROW_NAME.test(name)) return `A ${words.name.toLowerCase()} name is letters, digits, - and _, not ${name}.`;
    if (seen.has(name)) return `Two rows are named ${name}: one each.`;
    seen.add(name);
  }
  return null;
}

/** A free map as rows of a name and a value, with Remove on each and an add button under them. */
export function RowsControl({ spec, labelId, text, onChange }: ControlProps) {
  const words = spec.rows ?? { name: 'Name', value: 'Value', namePlaceholder: '', valuePlaceholder: '', add: 'Add' };
  const parse = (from: string): Row[] => mapEntries(from).map(([name, value]) => ({ name, value }));
  const [rows, setRows] = useDraft(text, parse, onChange);
  const write = (next: Row[]): void => setRows(next, mapText(next.filter((row) => row.name.trim() !== '' || row.value.trim() !== '').map((row): [string, string] => [row.name.trim(), row.value])));
  const problem = rowsProblem(spec, rows);
  const named = words.name.toLowerCase();
  return (
    <div className="flow-rows" role="group" aria-labelledby={labelId}>
      {rows.length === 0 && <p className="module-help flow-help">None yet.</p>}
      {rows.map((row, index) => (
        <div key={index} className="flow-row">
          <input className="input mono" type="text" aria-label={`${words.name} ${index + 1} name`} placeholder={words.namePlaceholder} value={row.name}
            onChange={(event) => write(rows.map((each, at) => (at === index ? { ...each, name: event.target.value } : each)))} />
          <input className="input mono" type="text" aria-label={`${words.name} ${index + 1} ${words.value.toLowerCase()}`} placeholder={words.valuePlaceholder} value={row.value}
            onChange={(event) => write(rows.map((each, at) => (at === index ? { ...each, value: event.target.value } : each)))} />
          <button type="button" className="button" aria-label={`Remove ${named} ${index + 1}`} onClick={() => write(rows.filter((_, at) => at !== index))}>Remove</button>
        </div>
      ))}
      <span><button type="button" className="button" onClick={() => write([...rows, { name: '', value: '' }])}>{words.add}</button></span>
      {problem !== null && <p className="module-help flow-help tone-failing" role="status">{problem}</p>}
    </div>
  );
}

/**
 * `jobs.workers` as a switch per host and a count beside each host that is on. A host off is left
 * out of the map, which the plugin reads the same as 0 (`_jobs.py workers`). The last host on
 * cannot be turned off, since a map that starts no worker stops the next job; Stop splitting
 * takes the whole key out instead, which gives each run its own --workers on its own host again.
 */
export function WorkersControl({ spec, labelId, text, onChange }: ControlProps) {
  const hosts = spec.counts?.keys ?? [];
  const entries = mapEntries(text);
  const countOf = (host: string): string | null => {
    const found = entries.find(([key]) => key === host);
    return found === undefined || found[1].trim() === '0' ? null : found[1];
  };
  const on = hosts.filter((host) => countOf(host) !== null);
  const write = (host: string, count: string | null): void => {
    onChange(mapText(hosts.flatMap((each): [string, string][] => {
      const value = each === host ? count : countOf(each);
      return value === null ? [] : [[each, value]];
    })));
  };
  const noteId = `${labelId}-note`;
  return (
    <div className="flow-workers" role="group" aria-labelledby={labelId}>
      {hosts.map((host) => {
        const count = countOf(host);
        const last = count !== null && on.length === 1;
        return (
          <div key={host} className="flow-worker">
            <label className="flow-switch">
              <input type="checkbox" role="switch" checked={count !== null} disabled={last} aria-describedby={last ? noteId : undefined}
                onChange={(event) => write(host, event.target.checked ? '1' : null)} />
              <span>{host}</span>
            </label>
            {count !== null
              ? <input className="input" type="number" min={1} max={spec.max} aria-label={`${host} workers`} value={count} onChange={(event) => write(host, event.target.value)} />
              : <span className="muted">no workers</span>}
          </div>
        );
      })}
      {on.length === 0 && <p className="module-help flow-help">Not split: each run of the next job starts its own workers (one, unless its schedule says more) on its own host. Turn a host on to split them across hosts.</p>}
      {on.length === 1 && (
        <p id={noteId} className="module-help flow-help">
          {on[0]} stays on: a split that starts no worker stops the next job before it claims anything.{' '}
          <button type="button" className="button" onClick={() => onChange('')}>Stop splitting</button>
        </p>
      )}
    </div>
  );
}

/** The job options a schedule of each job may carry beyond the builder's fields, as an example. */
const OWN_EXAMPLE: Record<string, string> = { next: '--wait', comments: 'gh#12', intake: '--batch 5 --keep-notes', retro: '--min-lessons 3', health: '--dry-run' };
const NEW_SCHEDULE: ScheduleParts = { when: { kind: 'every', count: '30', unit: 'm' }, form: { host: '', item: '', workers: '', maxSteps: '', model: '', effort: '' }, own: '' };

type Builder = { parts: ScheduleParts | null; typing: boolean; asText: boolean };

/**
 * A schedule as the Agents page sets one: when it runs as dropdowns and fields, then the host
 * (jobs.host unless one is picked), next's item and limits, the model, the effort and the job's
 * other options. A line the builder cannot hold whole stays a text box with a note; Edit as text
 * opens the box for any line, and Unschedule empties the key.
 */
export function ScheduleControl({ spec, labelId, text, onChange, jobsHost, workersSplit }: ControlProps & { jobsHost: string; workersSplit: boolean }) {
  const name = spec.path.split('.').at(-1) ?? '';
  const job = scheduleJob(name);
  const parse = (from: string): Builder => {
    const parts = from.trim() === '' ? null : scheduleParts(from, job, jobsHost);
    return { parts, typing: parts !== null && typedModel(parts.form, jobsHost), asText: from.trim() !== '' && parts === null };
  };
  const [builder, setBuilder] = useDraft(text, parse, onChange);
  const build = (parts: ScheduleParts, typing: boolean): void => setBuilder({ parts, typing, asText: false }, scheduleLine(parts, job));
  if (builder.asText || builder.parts === null && text.trim() !== '') {
    const readable = text.trim() !== '' && scheduleParts(text, job, jobsHost) !== null;
    return (
      <div className="flow-schedule" role="group" aria-labelledby={labelId}>
        <input className="input mono" type="text" aria-label={`${spec.label} as text`} value={text} placeholder="every 30m" onChange={(event) => setBuilder({ ...builder, asText: true }, event.target.value)} />
        <p className="module-help flow-help">
          {readable ? 'When it runs (every 30m, daily 02:00 or weekly sun 07:00), then its options.' : 'The builder cannot show this schedule whole, so it is edited as text: when it runs (every 30m, daily 02:00 or weekly sun 07:00), then its options.'}
        </p>
        {readable && <span><button type="button" className="button" onClick={() => setBuilder(parse(text), text)}>Use the builder</button></span>}
      </div>
    );
  }
  if (builder.parts === null) {
    return (
      <div className="flow-schedule" role="group" aria-labelledby={labelId}>
        <p className="module-help flow-help">Not scheduled: the {job} job runs only when you start it.</p>
        <span><button type="button" className="button" onClick={() => build(NEW_SCHEDULE, false)}>Schedule it</button></span>
      </div>
    );
  }
  const { parts } = builder;
  const run = runFormOver(parts.form, builder.typing, (form, typing) => build({ ...parts, form }, typing), () => {}, jobsHost);
  const problem = scheduleProblem('', parts.when) ?? startProblem({ ...parts.form, host: formHost(parts.form, jobsHost) });
  const doubled = name === 'next' && workersSplit && parts.form.workers.trim() !== '';
  return (
    <div className="flow-schedule" role="group" aria-labelledby={labelId}>
      <div className="start-form flow-schedule-form">
        <WhenFields when={parts.when} setWhen={(when) => build({ ...parts, when }, builder.typing)} />
        <RunFields run={run} pair={job !== 'next'} />
        <label className="field wide"><span>Other options</span>
          <input className="mono" placeholder={OWN_EXAMPLE[job] ?? ''} title={`Options of the ${job} job the fields above do not cover, as jobs/${job}.sh takes them.`} value={parts.own} onChange={(event) => build({ ...parts, own: event.target.value }, builder.typing)} />
        </label>
      </div>
      {problem !== null && <p className="module-help flow-help tone-failing" role="status">{problem}</p>}
      {doubled && <p className="module-help flow-help tone-failing" role="status">Workers per host (Next job) already splits this schedule&apos;s workers, and jobs.sh refuses both: leave Workers empty here.</p>}
      <span className="flow-schedule-buttons">
        <button type="button" className="button" onClick={() => setBuilder({ ...builder, asText: true }, text)}>Edit as text</button>
        <button type="button" className="button" onClick={() => setBuilder({ parts: null, typing: false, asText: false }, '')}>Unschedule</button>
      </span>
    </div>
  );
}
