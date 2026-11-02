import { useState } from 'react';
import type { RefObject } from 'react';
import { JOB_EFFORTS, JOB_HOSTS, JOB_MODELS, WEEK_DAYS } from './jobStart.ts';
import type { JobStartForm, ScheduleWhen } from './jobStart.ts';

/**
 * The fields a schedule or a run is set with, shared by the Agents page (Schedule, Run once,
 * Edit…) and the schedule builder of the settings: when it runs, and the host, item, limits,
 * filter, model and effort of the run.
 */

/** The model or effort option that leaves it to the config's jobs.<host>.model and effort. */
export const FROM_CONFIG = '';
const OTHER_MODEL = 'other';

/**
 * A run form and its changes: the model offers the host's own names, and a host change drops a
 * model or effort that host does not take. `hostDefault`, when given, is the host a form with no
 * host word runs on (jobs.host): the host picker then offers it as its own choice.
 */
export type RunForm = {
  form: JobStartForm;
  typing: boolean;
  hostDefault: string | null;
  change: (form: JobStartForm) => void;
  reset: () => void;
  pickHost: (host: string) => void;
  pickModel: (model: string) => void;
};

/** The host a form's models and efforts follow: its own, else the one it falls back to. */
export function formHost(form: JobStartForm, hostDefault: string | null): string {
  return form.host !== '' ? form.host : hostDefault ?? 'claude';
}

/** Whether a form's model is off its host's list, so the model shows as typed text. */
export function typedModel(form: JobStartForm, hostDefault: string | null = null): boolean {
  return form.model !== '' && !(JOB_MODELS[formHost(form, hostDefault)] ?? []).includes(form.model);
}

/** The run form's changes over a form and its typing flag, wherever the caller keeps them. */
export function runFormOver(form: JobStartForm, typing: boolean, set: (form: JobStartForm, typing: boolean) => void, reset: () => void, hostDefault: string | null = null): RunForm {
  return {
    form,
    typing,
    hostDefault,
    change: (next) => set(next, typing),
    reset,
    pickHost: (host) => {
      const to = formHost({ ...form, host }, hostDefault);
      set({ ...form, host, model: (JOB_MODELS[to] ?? []).includes(form.model) || typing ? form.model : FROM_CONFIG, effort: (JOB_EFFORTS[to] ?? []).includes(form.effort) ? form.effort : FROM_CONFIG }, typing);
    },
    pickModel: (model) => {
      if (model === OTHER_MODEL) { set({ ...form, model: '' }, true); return; }
      set({ ...form, model }, false);
    },
  };
}

/** next's run settings as a form kept here: `changed` hears every change but a reset. */
export function useRunForm(initial: JobStartForm, changed: () => void): RunForm {
  const [state, setState] = useState({ form: initial, typing: typedModel(initial) });
  return runFormOver(state.form, state.typing, (form, typing) => { setState({ form, typing }); changed(); }, () => setState({ form: initial, typing: typedModel(initial) }));
}

/**
 * The run's settings; `pair` shows only what every job takes: the host, the model and the effort.
 * `picks` are the filters pick in .flow/config.yaml names, offered for next's queue; a filter the
 * form names that the config no longer has stays offered, so it is never dropped unseen.
 */
export function RunFields({ run, pair = false, picks = [] }: { run: RunForm; pair?: boolean; picks?: readonly string[] }) {
  const { form, typing } = run;
  const filters = form.pick === '' || picks.includes(form.pick) ? picks : [...picks, form.pick];
  const host = formHost(form, run.hostDefault);
  const field = (name: keyof JobStartForm) => ({ value: form[name], onChange: (event: { target: { value: string } }) => run.change({ ...form, [name]: event.target.value }) });
  return (
    <>
      <label className="field"><span>Host</span>
        <select value={form.host} onChange={(event) => run.pickHost(event.target.value)}>
          {run.hostDefault !== null && <option value="">jobs.host ({run.hostDefault})</option>}
          {JOB_HOSTS.map((each) => <option key={each} value={each}>{each}</option>)}
        </select>
      </label>
      {!pair && (
        <>
          <label className="field"><span>Item</span><input placeholder="first ready item" title="A tracker id such as gh#81. Empty takes the first ready item each run." {...field('item')} /></label>
          <label className="field"><span>Workers</span><input inputMode="numeric" placeholder="1" title="How many items run at once, each in its own worktree." {...field('workers')} /></label>
          <label className="field"><span>Max steps</span><input inputMode="numeric" placeholder="no limit" title="The run stops after this many steps." {...field('maxSteps')} /></label>
          {filters.length > 0 && (
            <label className="field"><span>Filter</span>
              <select title="Takes only the ready items this filter of pick in .flow/config.yaml keeps." {...field('pick')}>
                <option value="">every ready item</option>
                {filters.map((name) => <option key={name} value={name}>{name}</option>)}
              </select>
            </label>
          )}
        </>
      )}
      <label className="field"><span>Model</span>
        <select value={typing ? OTHER_MODEL : form.model} onChange={(event) => run.pickModel(event.target.value)}>
          <option value={FROM_CONFIG}>From config</option>
          {(JOB_MODELS[host] ?? []).map((model) => <option key={model} value={model}>{model}</option>)}
          <option value={OTHER_MODEL}>Other…</option>
        </select>
      </label>
      {typing && <label className="field"><span>Model name</span><input placeholder={host === 'claude' ? 'claude-opus-5-5' : 'gpt-6-sol'} {...field('model')} /></label>}
      <label className="field"><span>Effort</span>
        <select {...field('effort')}>
          <option value={FROM_CONFIG}>From config</option>
          {(JOB_EFFORTS[host] ?? []).map((effort) => <option key={effort} value={effort}>{effort}</option>)}
        </select>
      </label>
    </>
  );
}

/** When a schedule runs: every so many minutes or hours, daily at a time, or weekly on a day at a time. */
export function WhenFields({ when, setWhen, first }: { when: ScheduleWhen; setWhen: (when: ScheduleWhen) => void; first?: RefObject<HTMLSelectElement> }) {
  const time = when.kind === 'every' ? '02:00' : when.time;
  return (
    <>
      <label className="field"><span>Runs</span>
        <select ref={first} value={when.kind} onChange={(event) => {
          const kind = event.target.value;
          setWhen(kind === 'every' ? { kind: 'every', count: '30', unit: 'm' } : kind === 'daily' ? { kind: 'daily', time } : { kind: 'weekly', day: 'mon', time });
        }}>
          <option value="every">every</option><option value="daily">daily</option><option value="weekly">weekly</option>
        </select>
      </label>
      {when.kind === 'every' && (
        <label className="field"><span>Every</span>
          <span className="prefixed">
            <input aria-label="Every" inputMode="numeric" value={when.count} onChange={(event) => setWhen({ ...when, count: event.target.value })} />
            <select aria-label="Unit" value={when.unit} onChange={(event) => setWhen({ ...when, unit: event.target.value as 'm' | 'h' })}><option value="m">min</option><option value="h">hours</option></select>
          </span>
        </label>
      )}
      {when.kind === 'weekly' && (
        <label className="field"><span>Day</span>
          <select value={when.day} onChange={(event) => setWhen({ ...when, day: event.target.value })}>{WEEK_DAYS.map((day) => <option key={day} value={day}>{day}</option>)}</select>
        </label>
      )}
      {when.kind !== 'every' && <label className="field"><span>At</span><input placeholder="02:00" value={when.time} onChange={(event) => setWhen({ ...when, time: event.target.value })} /></label>}
    </>
  );
}
