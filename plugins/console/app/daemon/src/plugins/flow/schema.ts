/**
 * What the console knows of the flow plugin's `.flow/config.yaml`: every key the plugin reads
 * (its scripts, `skills/init/SKILL.md` and the foosbrawl file), with its type, one sentence on what
 * changing it does, the group it shows in, and what has to happen after a change for it to count.
 * Pure data and checks, no I/O: the UI imports the types from here.
 */
import type { ActionKind } from '../../snapshot.ts';

export type FieldType = 'string' | 'number' | 'boolean' | 'enum' | 'list' | 'map' | 'duration' | 'schedule';

export const FIELD_GROUPS = ['Tracker', 'Readiness', 'Worktree pool', 'Gates and verification', 'Reviews', 'Notifications', 'Jobs', 'Intake'] as const;
export type FieldGroup = (typeof FIELD_GROUPS)[number] | 'Other';
/** Keys in the file the schema does not know: shown as text, still editable. */
export const OTHER_GROUP: FieldGroup = 'Other';

/** What a change needs before it counts: an action to run (with its button), or only a note. */
export type FollowUp = { note: string; action: { kind: ActionKind; label: string; args: Record<string, string> } | null };

export type FieldSpec = {
  /** The dotted path, such as `jobs.schedule.next`. */
  path: string;
  type: FieldType;
  help: string;
  group: FieldGroup;
  /** The allowed values of an enum. */
  values?: string[];
  min?: number;
  max?: number;
  followUp: FollowUp | null;
  /**
   * One host's own setting (`jobs.<host>.model` or `.effort`): the form shows it only while
   * `jobs.host` names that host, and its empty value is the host's default.
   */
  host?: { host: JobsHost; setting: 'model' | 'effort' };
  /** A key the flow no longer reads: shown only when the file sets it, read-only with this note and a Clear. */
  deprecated?: string;
};

export const JOBS_HOSTS = ['claude', 'codex'] as const;
export type JobsHost = (typeof JOBS_HOSTS)[number];
/** What the flow runs the jobs on when `jobs.host` is not set. */
export const DEFAULT_JOBS_HOST: JobsHost = 'claude';

/**
 * The model and effort a host takes when the file leaves them empty, as far as this machine says:
 * codex from `~/.codex/config.toml` (null when there is no such file), claude has no such file.
 */
export type HostDefaults = { codex: { model: string | null; effort: string | null } | null };

/** A change to one key: the new value, or null to take the key out of the file. */
export type FieldValue = string | number | boolean | string[] | Record<string, string> | null;
export type FieldChange = { path: string; value: FieldValue };

export type Section = { group: FieldGroup; fields: FieldSpec[] };

/** What `GET /api/projects/<id>/plugins/flow/config` returns, and a successful PUT too. */
export type FlowConfigDocument = {
  path: string;
  text: string;
  /** sha256 of `text`: a PUT sends it back, and a file changed on disk since is refused. */
  hash: string;
  /** The parsed file, or null when it is not in the flat format (then only Raw YAML can edit it). */
  values: Record<string, unknown> | null;
  sections: Section[];
  /** What in the file does not fit the schema, and why the file did not parse. */
  warnings: string[];
  /** The hosts' own defaults on this machine, for the help of `jobs.<host>.model` and `.effort`. */
  hostDefaults: HostDefaults;
};

/** A PUT's answer: the new document, the paths whose value changed, and what those changes need next. */
/** `notes`: what the save wants the owner to know, such as a file git does not track. */
export type FlowConfigSaved = FlowConfigDocument & { saved: string[]; followUps: (FollowUp & { paths: string[] })[]; notes: string[] };

const JOBS = ['next', 'comments', 'intake', 'retro', 'health'];
const ADAPTERS = ['github', 'local'];

const RELOAD_SCHEDULE: FollowUp = {
  note: 'The schedule launchd runs is written at install: run jobs.sh install to reload it.',
  action: { kind: 'jobs.install', label: 'Reload the schedule', args: {} },
};
const NEXT_CLAIM: FollowUp = { note: 'The pool reads this at the next claim; nothing to restart.', action: null };

const HOST_SETTINGS: Record<JobsHost, { model: string[]; effort: string[]; cli: string }> = {
  claude: { model: ['opus', 'sonnet', 'haiku', 'fable'], effort: ['low', 'medium', 'high', 'xhigh', 'max'], cli: 'Claude' },
  codex: { model: ['gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna'], effort: ['low', 'medium', 'high', 'xhigh'], cli: 'Codex' },
};
const DEPRECATED_JOBS = 'Deprecated: flow 1.20.0 reads jobs.<host>.model and jobs.<host>.effort. Set those and clear these.';

const field = (path: string, type: FieldType, group: FieldGroup, help: string, extra: Partial<FieldSpec> = {}): FieldSpec =>
  ({ path, type, group, help, followUp: null, ...extra });

export const FLOW_CONFIG_SCHEMA: FieldSpec[] = [
  field('adapters.default', 'enum', 'Tracker', 'Where new items go and are read from when their kind names no adapter of its own.', { values: ADAPTERS }),
  field('adapters.epic', 'enum', 'Tracker', 'Sends new epics to this tracker instead of the default one.', { values: ADAPTERS }),
  field('adapters.task', 'enum', 'Tracker', 'Sends new tasks to this tracker instead of the default one.', { values: ADAPTERS }),
  field('adapters.bug', 'enum', 'Tracker', 'Sends new bugs to this tracker instead of the default one, such as local to keep bugs off GitHub.', { values: ADAPTERS }),
  field('github.repo', 'string', 'Tracker', 'The owner/name repository whose issues and pull requests the flow reads and writes.'),
  field('github.limit', 'number', 'Tracker', 'How many issues one board read lists before it stops and says so.', { min: 1, max: 5000 }),
  field('github.types', 'boolean', 'Tracker', 'When on, an item\'s kind sets the GitHub issue type (Epic, Task, Bug) instead of a label.'),
  field('github.fields', 'map', 'Tracker', 'Maps the flow\'s size, priority and area to the names of the organisation\'s issue fields.'),
  field('github.project', 'number', 'Tracker', 'The GitHub project number whose Status column the flow keeps in step; unset leaves projects alone.', { min: 1 }),
  field('github.status', 'map', 'Tracker', 'Renames the project Status options the flow moves items to (backlog, ready, gate, running, review).'),
  field('github.answer_from', 'list', 'Tracker', 'The GitHub logins whose /answer comments clear a gate; empty, only the signed-in gh user\'s answers count.'),
  field('github.ready_needs', 'list', 'Readiness', 'The fields an unstarted item must have filled before the next job will take it.'),
  field('github.priority_order', 'list', 'Readiness', 'The priorities from most to least urgent; the next job takes ready items in this order.'),
  field('base', 'string', 'Worktree pool', 'The branch new task branches start from and pull requests merge into.'),
  field('pool', 'list', 'Worktree pool', 'The worktrees tasks are claimed into, one task each; more entries means more work in parallel.', { followUp: NEXT_CLAIM }),
  field('pool_max', 'number', 'Worktree pool', 'How far the pool may grow on its own when every worktree is busy; 0 never adds one.', { min: 0, max: 64, followUp: NEXT_CLAIM }),
  field('worktree_copy', 'list', 'Worktree pool', 'Git-ignored files a new worktree gets copied from the main checkout when it lacks them.', { followUp: NEXT_CLAIM }),
  field('worktree_setup', 'list', 'Worktree pool', 'Commands run in a new worktree after the copy, such as a package restore.', { followUp: NEXT_CLAIM }),
  field('gates', 'map', 'Gates and verification', 'Project checks the verifier runs after build, format and tests: a name and the command, run from the root.'),
  field('feel_test_paths', 'list', 'Gates and verification', 'Changed files matching these globs stop the item at the feel-test gate after verify passes.'),
  field('auto_gates.plan-approval', 'string', 'Gates and verification', 'Item sizes, comma separated (such as S,M), whose plan the flow approves itself instead of waiting for you.'),
  field('reviews.reviewers', 'list', 'Reviews', 'Who each review round asks: codex, claude, copilot or a GitHub login.'),
  field('reviews.chase_after', 'duration', 'Reviews', 'How long a reviewer may stay silent before the comments job asks again.'),
  field('reviews.max_chases', 'number', 'Reviews', 'How many times a silent reviewer is asked again before you are told.', { min: 0, max: 20 }),
  field('notify.desktop', 'boolean', 'Notifications', 'When on, notifications also show as a macOS banner on this machine.'),
  field('notify.slack_webhook', 'string', 'Notifications', 'The Slack incoming webhook notifications go to; empty sends none (FLOW_SLACK_WEBHOOK keeps the URL out of the repository).'),
  field('notify.idle', 'boolean', 'Notifications', 'When on, the scheduled next job tells you once when it finds nothing ready.'),
  field('notify.health', 'boolean', 'Notifications', 'When off, the health job stops notifying about old gates, diverged branches and a full pool.'),
  field('jobs.host', 'enum', 'Jobs', 'Which CLI runs the scheduled jobs. The workers inside a run keep their own models.', { values: [...JOBS_HOSTS], followUp: RELOAD_SCHEDULE }),
  // The next job run reads these from the file, so a change needs nothing after it.
  ...JOBS_HOSTS.flatMap((host) => [
    field(`jobs.${host}.model`, 'enum', 'Jobs', `The model the scheduled jobs' orchestrating session uses when they run on ${host}; empty takes the ${HOST_SETTINGS[host].cli} CLI's default.`, { values: HOST_SETTINGS[host].model, host: { host, setting: 'model' } }),
    field(`jobs.${host}.effort`, 'enum', 'Jobs', `The reasoning effort the scheduled jobs' orchestrating session uses when they run on ${host}; empty takes the ${HOST_SETTINGS[host].cli} CLI's default.`, { values: HOST_SETTINGS[host].effort, host: { host, setting: 'effort' } }),
  ]),
  field('jobs.model', 'string', 'Jobs', DEPRECATED_JOBS, { deprecated: DEPRECATED_JOBS }),
  field('jobs.effort', 'string', 'Jobs', DEPRECATED_JOBS, { deprecated: DEPRECATED_JOBS }),
  field('jobs.permission_mode', 'enum', 'Jobs', 'How unattended Claude sessions ask for tools: dontAsk denies every edit not allowed already, auto lets the classifier allow safe ones.', { values: ['dontAsk', 'auto'] }),
  field('jobs.marketplace', 'string', 'Jobs', 'The marketplace checkout the weekly retro opens its pull request from.'),
  ...JOBS.map((job) => field(`jobs.schedule.${job}`, 'schedule', 'Jobs', `When the ${job} job runs on this machine: every 30m, daily 02:00 or weekly sun 07:00, then its options.`, { followUp: RELOAD_SCHEDULE })),
  field('jobs.health.grace', 'duration', 'Jobs', 'How long a run record may show no live process before the health job calls the run dead.'),
  field('jobs.health.gate_reminder', 'duration', 'Jobs', 'How often a gate nobody answered gets a reminder.'),
  field('jobs.health.max_resumes', 'number', 'Jobs', 'How many times in a row the health job resumes cut-off work before it raises an escalation gate.', { min: 0, max: 20 }),
  field('jobs.health.behind_base', 'number', 'Jobs', 'How many commits behind the base a task branch may fall before the health job merges the base in.', { min: 1, max: 1000 }),
  field('jobs.health.push', 'boolean', 'Jobs', 'When on, the health job pushes a clean task branch that is only ahead of its remote.'),
  field('jobs.comments.max_failures', 'number', 'Jobs', 'How many failed passes in a row on one pull request before the comments job stops trying it and tells you.', { min: 1, max: 20 }),
  field('retro.commit', 'boolean', 'Jobs', 'When off, the retro job leaves the lessons it writes uncommitted.'),
  field('intake.notes', 'string', 'Intake', 'The notes file the nightly intake job turns into tracker items.'),
  field('intake.batch', 'number', 'Intake', 'How many notes one intake run files at most.', { min: 1, max: 100 }),
  field('intake.rules', 'string', 'Intake', 'The file that says how a note becomes an item: outcomes, type, area, priority.'),
  field('intake.answers', 'string', 'Intake', 'Where the intake job appends the answers it gave; empty puts answers.md beside the notes.'),
  field('intake.dropped', 'string', 'Intake', 'Where the intake job moves the notes it dropped, with the reason; empty puts dropped.md beside the notes.'),
  field('intake.commit', 'boolean', 'Intake', 'When off, the intake job leaves the notes file uncommitted after filing.'),
];

export function fieldAt(path: string): FieldSpec | undefined {
  return FLOW_CONFIG_SCHEMA.find((spec) => spec.path === path);
}

/** The schema field a path belongs to: itself, or the map or list field above it. */
export function fieldCovering(path: string): FieldSpec | undefined {
  return FLOW_CONFIG_SCHEMA.find((spec) => spec.path === path || ((spec.type === 'map' || spec.type === 'list') && path.startsWith(`${spec.path}.`)));
}

/** The fixed groups with their fields, in schema order. */
export function schemaSections(): Section[] {
  return FIELD_GROUPS.map((group) => ({ group, fields: FLOW_CONFIG_SCHEMA.filter((spec) => spec.group === group) }));
}

export type Checked = { ok: true } | { ok: false; error: string };
const ok: Checked = { ok: true };
const fail = (error: string): Checked => ({ ok: false, error });

const DURATION = /^[0-9]+[smhd]$/;
const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const CLOCK = /^([01]?[0-9]|2[0-3]):[0-5][0-9]$/;
/** One option or value after the schedule, as `_jobs.py` takes it: no globs, redirections or substitutions. */
const SCHEDULE_ARG = /^[A-Za-z0-9_./:=@%+,-]+$/;
const NUMBER = /^-?[0-9]+$/;

/** The schedule as `scripts/_jobs.py` reads it: every 30m, every 2h, daily 02:00 or weekly sun 03:00, then its args. */
export function checkSchedule(text: string): Checked {
  const words = text.split(/\s+/).filter((word) => word !== '');
  let args: string[] | null = null;
  if (words[0] === 'every' && words[1] !== undefined && /^[1-9][0-9]*[mh]$/.test(words[1])) args = words.slice(2);
  if (words[0] === 'daily' && words[1] !== undefined && CLOCK.test(words[1])) args = words.slice(2);
  if (words[0] === 'weekly' && words[1] !== undefined && WEEKDAYS.includes(words[1].slice(0, 3).toLowerCase()) && words[2] !== undefined && CLOCK.test(words[2])) args = words.slice(3);
  if (args === null) return fail(`cannot read the schedule "${text}": use every 30m, daily 02:00 or weekly sun 03:00`);
  const bad = args.find((arg) => !SCHEDULE_ARG.test(arg));
  return bad === undefined ? ok : fail(`the schedule "${text}" has the arg "${bad}": an arg is one option or value of letters, digits and _./:=@%+,-`);
}

function inRange(spec: FieldSpec, value: number): Checked {
  if (spec.min !== undefined && value < spec.min) return fail(`${spec.path} must be at least ${spec.min}`);
  if (spec.max !== undefined && value > spec.max) return fail(`${spec.path} must be at most ${spec.max}`);
  return ok;
}

/** A scalar as the file holds it (always text), checked against the field's type. An empty value means unset and always passes. */
function checkText(spec: FieldSpec, text: string): Checked {
  if (text === '') return ok;
  if (/^\s*[[{]/.test(text)) return fail(`${spec.path} starts with [ or {, which lib/flow.sh reads as a list even in quotes`);
  switch (spec.type) {
    case 'string': return ok;
    case 'number': return NUMBER.test(text) ? inRange(spec, Number(text)) : fail(`${spec.path} must be a whole number, not "${text}"`);
    case 'boolean': return text === 'true' || text === 'false' ? ok : fail(`${spec.path} must be true or false, not "${text}"`);
    case 'enum': return spec.values?.includes(text) === true ? ok : fail(`${spec.path} must be one of ${(spec.values ?? []).join(', ')}, not "${text}"`);
    case 'duration': return DURATION.test(text) ? ok : fail(`${spec.path} must be a number with s, m, h or d, like 10m or 24h, not "${text}"`);
    case 'schedule': { const checked = checkSchedule(text); return checked.ok ? ok : fail(`${spec.path}: ${checked.error}`); }
    case 'list': return ok;
    case 'map': return fail(`${spec.path} must be a map of name: value lines, not "${text}"`);
  }
}

/**
 * A value read from the file against its field. A list may be written as one scalar (the flow
 * reads it as a one-item list); a map whose entries are maps themselves (a gate with command and
 * paths) passes too, and is edited as raw YAML.
 */
export function checkFileValue(spec: FieldSpec, value: unknown): Checked {
  if (spec.type === 'list') {
    if (typeof value === 'string') return ok;
    // A bare key with no items is how the flat format writes an empty list.
    if (value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0) return ok;
    return Array.isArray(value) && value.every((entry) => typeof entry === 'string') ? ok : fail(`${spec.path} must be a list of text`);
  }
  if (spec.type === 'map') {
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) return ok;
    return fail(`${spec.path} must be a map of name: value lines`);
  }
  if (typeof value !== 'string') return fail(`${spec.path} must be one value, not a ${Array.isArray(value) ? 'list' : 'map'}`);
  return checkText(spec, value);
}

/** A change from the UI against its field: the JSON type the field takes, then the same checks as a value in the file. */
export function checkChange(spec: FieldSpec, value: FieldValue): Checked {
  if (value === null) return ok;
  switch (spec.type) {
    case 'number':
      if (typeof value !== 'number' || !Number.isInteger(value)) return fail(`${spec.path} must be a whole number`);
      return inRange(spec, value);
    case 'boolean': return typeof value === 'boolean' ? ok : fail(`${spec.path} must be true or false`);
    case 'list': return Array.isArray(value) && value.every((entry) => typeof entry === 'string') ? ok : fail(`${spec.path} must be a list of text`);
    case 'map':
      return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.entries(value).every(([key, entry]) => /^[A-Za-z0-9_-]+$/.test(key) && typeof entry === 'string')
        ? ok : fail(`${spec.path} must be a map of names (letters, digits, - and _) to text`);
    case 'string': case 'enum': case 'duration': case 'schedule':
      return typeof value === 'string' ? checkText(spec, value) : fail(`${spec.path} must be text`);
  }
}
