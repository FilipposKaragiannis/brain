/** The Run… form for the next job: one run with its own host, item and limits, outside the schedule. */
export type JobStartForm = { host: string; item: string; workers: string; maxSteps: string; model: string; effort: string };

export const JOB_HOSTS = ['claude', 'codex'] as const;
/** The jobs flow runs, and what each one does, as the side panel's picker says it. */
export const JOB_KINDS: Record<string, string> = {
  next: 'works the ready items, step by step',
  comments: 'answers review comments on open PRs',
  intake: 'turns your notes into tracker items',
  retro: 'reads the lessons log and proposes changes',
  health: 'checks the pool and the gates, and resumes dead runs',
};
/** The models flow names for each host (lib/host.sh maps the Claude names to these Codex ones). */
export const JOB_MODELS: Record<string, string[]> = { claude: ['opus', 'sonnet', 'haiku', 'fable'], codex: ['gpt-6-sol', 'gpt-6-luna', 'gpt-6-astra'] };
/** The efforts each host takes, as lib/host.sh checks them. */
export const JOB_EFFORTS: Record<string, string[]> = { claude: ['low', 'medium', 'high', 'xhigh', 'max'], codex: ['low', 'medium', 'high', 'xhigh'] };
/** The daemon's limits on a `job.start`. */
export const MAX_WORKERS = 99;
export const MAX_STEPS = 999;

/**
 * The form as the schedule would run it: the host, item, `--workers` and `--max-steps` the job's
 * arguments name, else the project's jobs host. Model and effort start empty, which means the
 * config's `jobs.<host>.model` and `effort`.
 */
export function startFormFrom(args: string, jobsHost: string): JobStartForm {
  const words = args.split(/\s+/).filter((word) => word !== '');
  const form: JobStartForm = { host: isHost(jobsHost) ? jobsHost : 'claude', item: '', workers: '', maxSteps: '', model: '', effort: '' };
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]!;
    const value = words[index + 1] ?? '';
    if (word === '--workers') { form.workers = value; index += 1; continue; }
    if (word === '--max-steps') { form.maxSteps = value; index += 1; continue; }
    if (word === '--model') { form.model = value; index += 1; continue; }
    if (word === '--effort') { form.effort = value; index += 1; continue; }
    if (word.startsWith('--')) continue;
    if (isHost(word)) form.host = word;
    else if (form.item === '') form.item = word;
  }
  return form;
}

/** The `job.start` arguments: the host always, every other field only when filled. */
export function startArgs(form: JobStartForm): Record<string, string> {
  const args: Record<string, string> = { host: form.host };
  const named: [keyof JobStartForm, string][] = [['item', 'item'], ['workers', 'workers'], ['maxSteps', 'maxSteps'], ['model', 'model'], ['effort', 'effort']];
  for (const [field, name] of named) {
    const value = form[field].trim();
    if (value !== '') args[name] = value;
  }
  return args;
}

/** What is wrong with the form, or null when it can run. */
export function startProblem(form: JobStartForm): string | null {
  if (!isHost(form.host)) return 'Pick claude or codex.';
  if (form.workers.trim() !== '' && !isCount(form.workers, MAX_WORKERS)) return `Workers is a whole number from 1 to ${MAX_WORKERS}.`;
  if (form.maxSteps.trim() !== '' && !isCount(form.maxSteps, MAX_STEPS)) return `Max steps is a whole number from 1 to ${MAX_STEPS}.`;
  if (/\s/.test(form.item.trim())) return 'One item, such as gh#12.';
  if (/\s/.test(form.model.trim())) return 'One model name, such as opus.';
  if (form.effort !== '' && !(JOB_EFFORTS[form.host] ?? []).includes(form.effort)) return `${form.host} takes ${(JOB_EFFORTS[form.host] ?? []).join(', ')} as effort.`;
  if (form.item.trim() !== '' && Number(form.workers) > 1) return 'One item runs on one worker. Clear the item or set workers to 1.';
  return null;
}

/** When a schedule runs: every so many minutes or hours, daily at a time, or weekly on a day at a time. */
export type ScheduleWhen = { kind: 'every'; count: string; unit: 'm' | 'h' } | { kind: 'daily'; time: string } | { kind: 'weekly'; day: string; time: string };

export const WEEK_DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const;
/** A label names a second schedule of the job (next-codex); it starts with a letter, so it never reads as a worker number. */
const LABEL = /^[a-z][a-z0-9]*$/;
const TIME = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;

/** The schedule's name: the job itself when the label is empty (its one schedule), else <job>-<label>. */
export function scheduleName(job: string, label: string): string {
  const trimmed = label.trim();
  return trimmed === '' ? job : `${job}-${trimmed}`;
}

/** What is wrong with a schedule's label or time, or null. */
export function scheduleProblem(label: string, when: ScheduleWhen): string | null {
  if (label.trim() !== '' && !LABEL.test(label.trim())) return 'A name is lower-case letters and digits, starting with a letter, such as codex.';
  if (when.kind === 'every') return isCount(when.count, Number.MAX_SAFE_INTEGER) ? null : 'Every takes a whole number, such as 30.';
  if (!TIME.test(when.time)) return 'A time is HH:MM, such as 02:00.';
  if (when.kind === 'weekly' && !(WEEK_DAYS as readonly string[]).includes(when.day)) return 'Pick a day.';
  return null;
}

/**
 * The schedule line flow keeps in jobs.schedule.<name>: when, then the host word and the run's
 * options, so the schedule runs what the form would run once.
 */
export function scheduleSpec(when: ScheduleWhen, form: JobStartForm): string {
  const args = startArgs(form);
  const words = [whenSpec(when), form.host];
  if (args.item !== undefined) words.push(args.item);
  const options: [string, string | undefined][] = [['--workers', args.workers], ['--max-steps', args.maxSteps], ['--model', args.model], ['--effort', args.effort]];
  for (const [option, value] of options) if (value !== undefined) words.push(option, value);
  return words.join(' ');
}

function isHost(word: string): boolean {
  return (JOB_HOSTS as readonly string[]).includes(word);
}

function isCount(value: string, most: number): boolean {
  return /^[1-9][0-9]*$/.test(value.trim()) && Number(value) <= most;
}

/** When, as the schedule line starts: "every 30m", "daily 02:00", "weekly sun 07:00". */
export function whenSpec(when: ScheduleWhen): string {
  return when.kind === 'every' ? `every ${when.count.trim()}${when.unit}` : when.kind === 'daily' ? `daily ${when.time}` : `weekly ${when.day} ${when.time}`;
}

/** The form's time fields from a job's schedule ("every 30m", "daily 02:00", "weekly sun 07:00"); every 30m when it says none. */
export function whenFrom(schedule: string): ScheduleWhen {
  const words = schedule.trim().split(/\s+/);
  const every = words[0] === 'every' ? /^(\d+)([mh])$/.exec(words[1] ?? '') : null;
  if (every !== null) return { kind: 'every', count: every[1]!, unit: every[2] as 'm' | 'h' };
  if (words[0] === 'daily' && words[1] !== undefined) return { kind: 'daily', time: words[1] };
  if (words[0] === 'weekly' && words[2] !== undefined) return { kind: 'weekly', day: words[1]!, time: words[2] };
  return { kind: 'every', count: '30', unit: 'm' };
}

/**
 * What stops a new schedule's name: the side panel only adds, so an existing name is changed
 * from its row instead. An empty name is the job's own schedule, free only while it has none.
 */
export function newScheduleProblem(job: string, label: string, taken: readonly string[]): string | null {
  const name = scheduleName(job, label);
  if (!taken.includes(name)) return null;
  if (name === job) return `Name the new schedule, such as codex: ${job} already has one. Change ${job} with Edit… on its row.`;
  return `${name} already exists. Change it with Edit… on its row.`;
}

/** A job's own arguments: its args without the host word, --model and --effort, which the form sets. */
export function ownArgs(args: string): string[] {
  const words = args.split(/\s+/).filter((word) => word !== '');
  const kept: string[] = [];
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]!;
    if (word === '--model' || word === '--effort') { index += 1; continue; }
    if (index === 0 && isHost(word)) continue;
    kept.push(word);
  }
  return kept;
}

/**
 * The schedule line of a job other than next: when, the host word, the job's own arguments as
 * they were, then the model and effort when set.
 */
export function pairSpec(when: ScheduleWhen, form: JobStartForm, args: string): string {
  const words = [whenSpec(when), form.host, ...ownArgs(args)];
  if (form.model.trim() !== '') words.push('--model', form.model.trim());
  if (form.effort !== '') words.push('--effort', form.effort);
  return words.join(' ');
}
