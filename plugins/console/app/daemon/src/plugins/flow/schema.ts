/**
 * What the console knows of the flow plugin's `.flow/config.yaml`: every key the plugin reads
 * (its scripts, `skills/init/SKILL.md` and the foosbrawl file), with its type, one sentence on what
 * changing it does, the group it shows in, and what has to happen after a change for it to count.
 * Pure data and checks, no I/O: the UI imports the types from here.
 */
import type { ActionKind } from '../../snapshot.ts';

/** `enumOrText`: the known values to pick from, but any text passes (the plugin passes a model name on as is). */
export type FieldType = 'string' | 'number' | 'boolean' | 'enum' | 'enumOrText' | 'list' | 'map' | 'duration' | 'schedule';

export const FIELD_GROUPS = [
  'Tracker', 'Readiness', 'Worktree pool', 'Gates and verification', 'Reviews', 'Notifications',
  'Schedules', 'Next job', 'Health job', 'Comments job', 'Retro job', 'Intake job',
  'Agents',
] as const;
export type FieldGroup = (typeof FIELD_GROUPS)[number] | 'Other';
/** Where a group sits in the Settings menu: the flow plugin's own pages, the jobs' pages, or the agents' page. */
export type GroupFamily = 'Flow' | 'Jobs' | 'Agents';
export const GROUP_FAMILY: Record<(typeof FIELD_GROUPS)[number], GroupFamily> = {
  'Tracker': 'Flow', 'Readiness': 'Flow', 'Worktree pool': 'Flow', 'Gates and verification': 'Flow', 'Reviews': 'Flow', 'Notifications': 'Flow',
  'Schedules': 'Jobs', 'Next job': 'Jobs', 'Health job': 'Jobs', 'Comments job': 'Jobs', 'Retro job': 'Jobs', 'Intake job': 'Jobs',
  'Agents': 'Agents',
};
/** Keys in the file the schema does not know: shown as text, still editable. */
export const OTHER_GROUP: FieldGroup = 'Other';

/** What a change needs before it counts: an action to run (with its button), or only a note. */
export type FollowUp = { note: string; action: { kind: ActionKind; label: string; args: Record<string, string> } | null };

export type FieldSpec = {
  /** The dotted path, such as `jobs.schedule.next`. */
  path: string;
  type: FieldType;
  /** What the form calls the key, in plain words; the path shows beside it. */
  label: string;
  help: string;
  group: FieldGroup;
  /** The allowed values of an enum, or the known ones of an enumOrText. */
  values?: string[];
  min?: number;
  max?: number;
  followUp: FollowUp | null;
  /**
   * One host's own setting (`jobs.<host>.model` or `.effort`): the form shows it only while
   * `jobs.host` names that host, and its empty value is the host's default.
   */
  host?: { host: JobsHost; setting: 'model' | 'effort' };
  /** A key on its way out: shown only when the file sets it, read-only with this note and a Clear. */
  deprecated?: string;
  /**
   * A map of counts under fixed names (`jobs.workers`: each host to its workers): only these names,
   * each a whole number from `min` to `max`, and at least one above 0. The plugin also reads such a
   * map on one line, `{claude: 1, codex: 2}`; a file that holds it so keeps that form when edited.
   */
  counts?: { keys: string[] };
  /** The subheading the field sits under inside its page, such as GitHub in Tracker; none sits at the top. */
  part?: string;
  /** A concrete example, shown greyed in the empty control (lines of a list on their own lines). */
  placeholder?: string;
  /** Read by one tracker's adapter only: the form hides it while no tracker of the project is that one. */
  adapter?: TrackerAdapter;
  /**
   * A map under fixed names (`github.status`: backlog, ready, …): one labelled box per name, an
   * empty box leaves the name out, and no other name passes the check.
   */
  keys?: MapKey[];
  /** A map of free names to text (`gates`: a check to its command), edited as rows of a name and a value. */
  rows?: MapRows;
  /**
   * The key that may hold one plain list in place of the map this field sits in (`reviews.reviewers`
   * for its `default`): the form shows that list as this field's value, and a save under the map
   * turns the list into this field first.
   */
  plainList?: string;
  /**
   * An empty value is no value (a pick filter's field): a save of "" or [] takes the key out, as
   * flow reads an empty key the same as none and a key left behind would read as set to a reader
   * of the file.
   */
  emptyUnset?: true;
};

/** One fixed name of a map: the name the file writes, what the form calls it, and an example. */
export type MapKey = { name: string; label: string; placeholder: string };
/** What the rows of a free map call their two boxes, an example of each, and the add button's words. */
export type MapRows = { name: string; value: string; namePlaceholder: string; valuePlaceholder: string; add: string };

export const JOBS_HOSTS = ['claude', 'codex'] as const;
export type JobsHost = (typeof JOBS_HOSTS)[number];
/** What the flow runs the jobs on when `jobs.host` is not set. */
export const DEFAULT_JOBS_HOST: JobsHost = 'claude';

/**
 * The model and effort a host takes when the file leaves them empty, as far as this machine says:
 * codex from `~/.codex/config.toml` (null when there is no such file), claude has no such file.
 */
export type HostDefaults = { codex: { model: string | null; effort: string | null; profile: string | null } | null };

/** The roster's Claude names as codex takes them, as `host_codex_model` in the plugin's lib/host.sh maps them. */
const CODEX_FROM_ROSTER: Record<string, string> = { sonnet: 'gpt-6-luna', opus: 'gpt-6-sol', fable: 'gpt-6-astra', haiku: 'gpt-6-luna' };

/**
 * What the plugin (flow 1.20.0, `host_jobs_pair` in lib/host.sh) still takes from the deprecated
 * `jobs.model` or `jobs.effort` for a host whose `jobs.<host>` map is absent: the value it runs
 * with and the key it came from, or null when the host's own map is there or the old key is
 * empty. A codex model there is a roster name, mapped the way the plugin maps it.
 */
export function legacyJobsSetting(values: Record<string, unknown>, host: JobsHost, setting: 'model' | 'effort'): { value: string; from: string } | null {
  const jobs = values['jobs'];
  if (jobs === null || typeof jobs !== 'object' || Array.isArray(jobs)) return null;
  const map = jobs as Record<string, unknown>;
  if (map[host] !== undefined) return null;
  const old = map[setting];
  if (typeof old !== 'string' || old === '') return null;
  return { value: host === 'codex' && setting === 'model' ? CODEX_FROM_ROSTER[old] ?? old : old, from: `jobs.${setting}` };
}

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

/** The jobs `jobs.sh` knows, each a script under the plugin's jobs/. */
export const FLOW_JOBS = ['next', 'comments', 'intake', 'retro', 'health'];
const JOBS = FLOW_JOBS;
/**
 * A schedule's name, as jobs.sh takes it: a job (`next`), or `<job>-<label>` for another schedule
 * of the same job (`next-nightly`), the label a lower case word. A worker's name, `<schedule>-<n>`,
 * never reads as one, since a label opens with a letter.
 */
export const SCHEDULE_NAME = new RegExp(`^(${JOBS.join('|')})(-[a-z][a-z0-9]*)?$`);
const SCHEDULE_PREFIX = 'jobs.schedule.';

/** The job a schedule runs: its name up to the label (`next` for `next-nightly`). */
export function scheduleJob(name: string): string {
  return name.split('-')[0] ?? name;
}
const ADAPTERS = ['github', 'local', 'jira'];
/** The adapters with keys of their own in the file, each shown only while it is a tracker of the project. */
export const TRACKER_ADAPTERS = ['github', 'jira'] as const;
export type TrackerAdapter = (typeof TRACKER_ADAPTERS)[number];

const RELOAD_SCHEDULE: FollowUp = {
  note: 'The schedule launchd runs is written at install: run jobs.sh install to reload it.',
  action: { kind: 'jobs.install', label: 'Reload the schedule', args: {} },
};
const NEXT_CLAIM: FollowUp = { note: 'The pool reads this at the next claim; nothing to restart.', action: null };

const HOST_SETTINGS: Record<JobsHost, { model: string[]; effort: string[]; cli: string }> = {
  claude: { model: ['opus', 'sonnet', 'haiku', 'fable'], effort: ['low', 'medium', 'high', 'xhigh', 'max'], cli: 'Claude' },
  codex: { model: ['gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna'], effort: ['low', 'medium', 'high', 'xhigh'], cli: 'Codex' },
};
/** `low, medium or high`: a list as a sentence says it. */
const saidList = (values: string[]): string => values.length < 2 ? values.join('') : `${values.slice(0, -1).join(', ')} or ${values[values.length - 1]}`;
const DEPRECATED_JOBS = 'Deprecated: flow 1.20.0 reads jobs.<host>.model and jobs.<host>.effort, and this key only while jobs.<host> is absent. Set those and clear these.';

const field = (path: string, type: FieldType, group: FieldGroup, label: string, help: string, extra: Partial<FieldSpec> = {}): FieldSpec =>
  ({ path, type, group, label, help, followUp: null, ...extra });
const capitalised = (word: string): string => `${word.charAt(0).toUpperCase()}${word.slice(1)}`;

const READ_FROM = 'Where items come from';
const TRACKERS = 'Where new items go';
const GITHUB = 'GitHub';
const JIRA = 'Jira';
const DEPRECATED_READY = 'Deprecated: flow reads ready.needs and ready.priority_order for every tracker, and this key only while that one is unset. Set it and clear this.';
const CHANNELS = 'Channels';
const WHEN_TO_NOTIFY = 'When to notify';
/** The project Status names the GitHub adapter moves cards to unless github.status renames them (adapters/github/_mutate.py STATUS). */
export const GITHUB_STATUS: MapKey[] = [
  { name: 'backlog', label: 'Backlog', placeholder: 'Backlog' },
  { name: 'ready', label: 'Ready', placeholder: 'Ready' },
  { name: 'gate', label: 'Waiting on you (a gate)', placeholder: 'Needs you' },
  { name: 'running', label: 'Being worked on', placeholder: 'In progress' },
  { name: 'review', label: 'Pull request in review', placeholder: 'In review' },
];
/** The fields an unstarted item can be made to need before it is ready, the ones `ready_rules` in the plugin's lib/flow.sh knows. */
export const READY_NEEDS = ['priority', 'size'];
/** Each readiness key and the deprecated GitHub key the plugin reads in its place while it is unset. */
const LEGACY_READY: Record<string, string> = { 'ready.needs': 'github.ready_needs', 'ready.priority_order': 'github.priority_order' };

/**
 * What the plugin (`ready_rules` in lib/flow.sh) still takes from `github.ready_needs` or
 * `github.priority_order` for a readiness key the file leaves out: the list and the key it came
 * from, or null when the file has the new key (an empty list too), the old one is empty, or the
 * path is no readiness key.
 */
export function legacyReadySetting(values: Record<string, unknown>, path: string): { value: string[]; from: string } | null {
  const from = LEGACY_READY[path];
  if (from === undefined || entryAt(values, path) !== undefined) return null;
  const old = listAt(values, from);
  return old.length === 0 ? null : { value: old, from };
}

/** The parsed file's entry at a dotted path, undefined when the file has no such key. */
function entryAt(values: Record<string, unknown>, path: string): unknown {
  return path.split('.').reduce<unknown>((at, key) => (at !== null && typeof at === 'object' && !Array.isArray(at) ? (at as Record<string, unknown>)[key] : undefined), values);
}

/** A list in the parsed file at a dotted path; one scalar is a one-item list, as lib/flow.sh reads it. */
function listAt(values: Record<string, unknown>, path: string): string[] {
  const value = entryAt(values, path);
  if (typeof value === 'string') return value === '' ? [] : [value];
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : [];
}
const INTAKE_PATH = 'A path from the project root, from ~/ or absolute.';

export const FLOW_CONFIG_SCHEMA: FieldSpec[] = [
  field('trackers', 'list', 'Tracker', 'Trackers the flow reads', 'The trackers the board, the next job and the health job read items from. Every tracker new items go to must be one of them. Unset, every tracker named below, and local.', { values: ADAPTERS, part: READ_FROM }),
  field('adapters.default', 'enum', 'Tracker', 'Tracker for new items', 'Where new items go when their kind names no tracker of its own. Unset, local: items live as files in the project.', { values: ADAPTERS, part: TRACKERS }),
  field('adapters.epic', 'enum', 'Tracker', 'Tracker for epics', 'Sends new epics to this tracker instead of the default one.', { values: ADAPTERS, part: TRACKERS }),
  field('adapters.task', 'enum', 'Tracker', 'Tracker for tasks', 'Sends new tasks to this tracker instead of the default one.', { values: ADAPTERS, part: TRACKERS }),
  field('adapters.bug', 'enum', 'Tracker', 'Tracker for bugs', 'Sends new bugs to this tracker instead of the default one, such as local to keep bugs off GitHub.', { values: ADAPTERS, part: TRACKERS }),
  field('github.repo', 'string', 'Tracker', 'GitHub repository', 'The owner/name repository whose pull requests the flow reads and writes, whatever tracker holds the items, and whose issues it reads while github is a tracker. Unset, the repository of the checkout\'s origin, as gh repo view names it; the console reads pull requests only when it is set.', { part: GITHUB, placeholder: 'acme/app' }),
  field('github.limit', 'number', 'Tracker', 'Issues per board read', 'How many issues one board read lists before it stops and says so. Unset, 500.', { min: 1, max: 5000, part: GITHUB, adapter: 'github', placeholder: '500' }),
  field('github.types', 'boolean', 'Tracker', 'Use GitHub issue types', 'When on, an item\'s kind sets the GitHub issue type (Epic, Task, Bug) instead of a label.', { part: GITHUB, adapter: 'github' }),
  field('github.fields', 'map', 'Tracker', 'Issue field names', 'The organisation\'s issue fields the flow fills in, by their name on GitHub. Without a size field the size goes in a size: label; without a priority field an item has no priority; without an area field the body names the area.', {
    part: GITHUB, adapter: 'github',
    keys: [{ name: 'size', label: 'Size field', placeholder: 'Size' }, { name: 'priority', label: 'Priority field', placeholder: 'Priority' }, { name: 'area', label: 'Area field', placeholder: 'Area' }],
  }),
  field('github.project', 'number', 'Tracker', 'GitHub project number', 'The number of a GitHub Projects board, from its URL (…/projects/<n>). The flow moves each item\'s card to the Status that says where the item is: Backlog, Ready, Needs you, In progress or In review. Unset leaves projects alone.', { min: 1, part: GITHUB, adapter: 'github', placeholder: '7' }),
  field('github.status', 'map', 'Tracker', 'Project status names', 'The Status options of that board, when yours are named differently. An empty box keeps the name shown in it.', { part: GITHUB, adapter: 'github', keys: GITHUB_STATUS }),
  field('github.answer_from', 'list', 'Tracker', 'Who may answer gates', 'The GitHub logins whose /answer comments on an issue clear its gate; empty, only the signed-in gh user\'s answers count.', { part: GITHUB, adapter: 'github', placeholder: 'octocat\nmonalisa' }),
  field('jira.site', 'string', 'Tracker', 'Jira site', 'The https address of the Jira Cloud site the items live on. The API token is JIRA_API_TOKEN in the environment of the console and the jobs, never a key of this file.', { part: JIRA, adapter: 'jira', placeholder: 'https://acme.atlassian.net' }),
  field('jira.project', 'string', 'Tracker', 'Jira project key', 'The key of the project whose issues are the items; ids read jira:<KEY>-<n>.', { part: JIRA, adapter: 'jira', placeholder: 'WID' }),
  field('jira.email', 'string', 'Tracker', 'Jira login', 'The email of the Jira account the API token belongs to.', { part: JIRA, adapter: 'jira', placeholder: 'you@acme.com' }),
  field('jira.types', 'map', 'Tracker', 'Issue type of each kind', 'The issue type an epic, a task and a bug are created as and read back from; an issue of any other type reads as a task. An empty box keeps the name shown in it.', {
    part: JIRA, adapter: 'jira',
    keys: [{ name: 'epic', label: 'Epic type', placeholder: 'Epic' }, { name: 'task', label: 'Task type', placeholder: 'Task' }, { name: 'bug', label: 'Bug type', placeholder: 'Bug' }],
  }),
  field('jira.fields', 'map', 'Tracker', 'Custom field names', 'The custom fields, by name or id (customfield_10040), that hold the size and the area. Without a size field the size goes in a size: label; without an area field the area is not kept.', {
    part: JIRA, adapter: 'jira',
    keys: [{ name: 'size', label: 'Size field', placeholder: 'Size' }, { name: 'area', label: 'Area field', placeholder: 'Area' }],
  }),
  field('jira.transitions.done', 'string', 'Tracker', 'Transition that closes', 'The workflow transition the flow takes to close an item. Unset, the first transition named Done.', { part: JIRA, adapter: 'jira', placeholder: 'Done' }),
  field('jira.limit', 'number', 'Tracker', 'Jira issues per board read', 'How many issues one board read lists before it stops and says so. Unset, 500.', { min: 1, max: 5000, part: JIRA, adapter: 'jira', placeholder: '500' }),
  field('jira.answer_from', 'list', 'Tracker', 'Who may answer gates on Jira', 'The Jira account ids or emails whose /answer comments on an issue clear its gate; empty, only the API token\'s own user\'s answers count.', { part: JIRA, adapter: 'jira', placeholder: 'you@acme.com\n5b10a2844c20165700ede21g' }),
  field('ready.needs', 'list', 'Readiness', 'Fields an item needs to start', 'The fields an unstarted item must have filled before the next job will take it, on every tracker.', { values: READY_NEEDS }),
  field('ready.priority_order', 'list', 'Readiness', 'Priority order', 'The priorities from most to least urgent, on every tracker; the next job takes ready items in this order, items with no priority last.', { placeholder: 'P0\nP1\nP2' }),
  field('github.ready_needs', 'list', 'Readiness', 'Fields an item needs (deprecated)', DEPRECATED_READY, { values: READY_NEEDS, deprecated: DEPRECATED_READY, part: 'Deprecated' }),
  field('github.priority_order', 'list', 'Readiness', 'Priority order (deprecated)', DEPRECATED_READY, { deprecated: DEPRECATED_READY, part: 'Deprecated' }),
  field('base', 'string', 'Worktree pool', 'Base branch', 'The branch new task branches start from and pull requests merge into. Unset, main.', { placeholder: 'main' }),
  field('pool', 'list', 'Worktree pool', 'Pool worktrees', 'The worktrees tasks are claimed into, one task each; more entries means more work in parallel.', { followUp: NEXT_CLAIM, placeholder: '../app-wt-1\n../app-wt-2' }),
  field('pool_max', 'number', 'Worktree pool', 'Most worktrees the pool grows to', 'A cap on the whole pool, not per run. When a claim finds every worktree busy, the flow adds one more worktree and lists it under Pool worktrees, until that list has this many entries: with 2 worktrees there and 9 here, the pool can grow by 7 more. 0 or unset never adds one.', { min: 0, max: 64, followUp: NEXT_CLAIM, placeholder: '4' }),
  field('worktree_name', 'string', 'Worktree pool', 'Name of a new worktree', 'The path a worktree the pool adds gets, from the project root: {repo} is the main checkout\'s folder and {n} the first number no pool entry or folder uses, and the last folder name must hold {n}. Unset, the next number after the last entry\'s name.', { followUp: NEXT_CLAIM, placeholder: '../{repo}-wt-{n}' }),
  field('worktree_copy', 'list', 'Worktree pool', 'Files copied into a new worktree', 'Git-ignored files a new worktree gets copied from the main checkout when it lacks them, as paths from the project root.', { followUp: NEXT_CLAIM, placeholder: '.env\n.claude/settings.local.json' }),
  field('worktree_setup', 'list', 'Worktree pool', 'Setup commands for a new worktree', 'Commands run in a new worktree after the copy, such as a package restore.', { followUp: NEXT_CLAIM, placeholder: 'npm ci' }),
  field('gates', 'map', 'Gates and verification', 'Project checks', 'Project checks the verifier runs after build, format and tests: a name, and the command it runs from the project root.', { rows: { name: 'Check', value: 'Command', namePlaceholder: 'lint', valuePlaceholder: 'npm run lint', add: 'Add a check' } }),
  field('feel_test_paths', 'list', 'Gates and verification', 'Paths that need a feel test', 'Changed files matching these globs stop the item at the feel-test gate after verify passes, for you to try the change by hand.', { placeholder: 'ui/src/**/*.tsx' }),
  field('auto_gates.plan-approval', 'string', 'Gates and verification', 'Sizes whose plan is approved for you', 'Item sizes, comma separated, whose plan the flow approves itself instead of waiting for you.', { placeholder: 'S,M' }),
  field('reviews.reviewers.claude', 'list', 'Reviews', 'Reviewers of Claude\'s PRs', 'Who each review round asks on a PR Claude wrote: codex, claude, copilot or a GitHub login. Empty, the default reviewers.', { placeholder: 'codex\ncopilot' }),
  field('reviews.reviewers.codex', 'list', 'Reviews', 'Reviewers of Codex\'s PRs', 'Who each review round asks on a PR Codex wrote. Empty, the default reviewers.', { placeholder: 'claude\ncopilot' }),
  field('reviews.reviewers.default', 'list', 'Reviews', 'Default reviewers', 'Who each review round asks on a PR whose author is unknown or has no list of its own. Unset, codex and claude.', { placeholder: 'codex\nclaude', plainList: 'reviews.reviewers' }),
  field('reviews.chase_after', 'duration', 'Reviews', 'Ask a silent reviewer again after', 'How long a reviewer may stay silent before the comments job asks again: a number with s, m, h or d. Unset, 1h.', { placeholder: '1h' }),
  field('reviews.max_chases', 'number', 'Reviews', 'Most times to ask again', 'How many times a silent reviewer is asked again before you are told. Unset, 2.', { min: 0, max: 20, placeholder: '2' }),
  field('notify.desktop', 'boolean', 'Notifications', 'Desktop banners', 'When on, notifications also show as a macOS banner on this machine.', { part: CHANNELS }),
  field('notify.slack_webhook', 'string', 'Notifications', 'Slack webhook (fallback)', 'Slack gets the notifications through an incoming webhook, and flow looks for it in the FLOW_SLACK_WEBHOOK environment variable first (export it in ~/.zprofile: the scheduled jobs run in a zsh login shell). This box is only the fallback when the variable is unset, and its URL is committed to the repository with .flow/config.yaml. Neither set, nothing goes to Slack.', { part: CHANNELS, placeholder: 'https://hooks.slack.com/services/…' }),
  field('notify.idle', 'boolean', 'Notifications', 'Tell me when nothing is ready', 'When on, the scheduled next job tells you once when it finds nothing ready.', { part: WHEN_TO_NOTIFY }),
  field('notify.health', 'boolean', 'Notifications', 'Health job notifications', 'When off, the health job stops notifying about old gates, diverged branches and a full pool.', { part: WHEN_TO_NOTIFY }),
  field('jobs.host', 'enum', 'Schedules', 'Host for scheduled jobs', 'Which CLI runs the scheduled jobs whose schedule names no host. The workers inside a run keep their own models.', { values: [...JOBS_HOSTS], followUp: RELOAD_SCHEDULE }),
  // The next job run reads these from the file, so a change needs nothing after it.
  ...JOBS_HOSTS.flatMap((host) => [
    field(`jobs.${host}.model`, 'enumOrText', 'Agents', `${HOST_SETTINGS[host].cli} model`, `The model of every unattended session on ${host} without an agent of its own: the steps with no agent (design, implement, review, explain) and the comments, intake and retro jobs. A known one or any name the ${HOST_SETTINGS[host].cli} CLI takes; empty takes the ${HOST_SETTINGS[host].cli} CLI's default.`, { values: HOST_SETTINGS[host].model, host: { host, setting: 'model' }, part: HOST_SETTINGS[host].cli }),
    field(`jobs.${host}.effort`, 'enum', 'Agents', `${HOST_SETTINGS[host].cli} effort`, `The reasoning effort of those same sessions on ${host}: ${saidList(HOST_SETTINGS[host].effort)}, the values flow accepts; empty takes the ${HOST_SETTINGS[host].cli} CLI's default.`, { values: HOST_SETTINGS[host].effort, host: { host, setting: 'effort' }, part: HOST_SETTINGS[host].cli }),
    ...(host === 'claude' ? [field('jobs.permission_mode', 'enum', 'Agents', 'Tool permission mode', 'How unattended Claude sessions ask for tools: dontAsk denies every edit not allowed already, auto lets the classifier allow safe ones.', { values: ['dontAsk', 'auto'], part: HOST_SETTINGS.claude.cli })] : []),
  ]),
  field('jobs.model', 'string', 'Agents', 'Model (deprecated)', DEPRECATED_JOBS, { deprecated: DEPRECATED_JOBS, part: 'Deprecated' }),
  field('jobs.effort', 'string', 'Agents', 'Effort (deprecated)', DEPRECATED_JOBS, { deprecated: DEPRECATED_JOBS, part: 'Deprecated' }),
  // jobs/next.sh reads it at every run of the queue (lib/workers.sh), so a change needs nothing after it.
  field('jobs.workers', 'map', 'Next job', 'Workers per host', 'How many workers a run of the next job starts on each host, numbered claude first (claude 1 and codex 2 is next-1 on claude, next-2 and next-3 on codex). A host turned off starts none. A run given its own workers, the next schedule\'s too, starts that many on its own host instead, and jobs.sh refuses the next schedule naming workers while this is set.', { counts: { keys: [...JOBS_HOSTS] }, min: 0, max: 64 }),
  field('jobs.marketplace', 'string', 'Retro job', 'Marketplace checkout', 'The folder of your checkout of the brain marketplace (the repository the flow plugin comes from). The weekly retro opens its pull request of plugin lessons from there; lessons about this project go in a report instead.', { placeholder: '~/work/brain' }),
  ...JOBS.map((job) => field(`jobs.schedule.${job}`, 'schedule', 'Schedules', `${capitalised(job)} job schedule`, `When the ${job} job runs on this machine, and what it runs with.`, { followUp: RELOAD_SCHEDULE })),
  field('jobs.health.grace', 'duration', 'Health job', 'Grace before a run counts as dead', 'How long a run record may show no live process before the health job calls the run dead. Unset, 10m.', { placeholder: '10m' }),
  field('jobs.health.stale_session', 'duration', 'Health job', 'Idle before a session counts as stale', 'How long an interactive Claude or Codex session may sit idle in a worktree (a Codex session, which never says it is idle: run) before the health job and the console call it stale. The comments job skips the PR of a worktree a session sits in, so a stale one holds that PR up. Unset, 24h.', { placeholder: '24h' }),
  field('jobs.health.gate_reminder', 'duration', 'Health job', 'Remind about an open gate every', 'How often a gate nobody answered gets a reminder. Unset, 24h.', { placeholder: '24h' }),
  field('jobs.health.max_resumes', 'number', 'Health job', 'Most resumes in a row', 'How many times in a row the health job resumes cut-off work before it raises an escalation gate. Unset, 3.', { min: 0, max: 20, placeholder: '3' }),
  field('jobs.health.behind_base', 'number', 'Health job', 'Commits behind before the base is merged in', 'How many commits behind the base a task branch may fall before the health job merges the base in. Unset, 20.', { min: 1, max: 1000, placeholder: '20' }),
  field('jobs.health.push', 'boolean', 'Health job', 'Push clean task branches', 'When on, the health job pushes a clean task branch that is only ahead of its remote.'),
  field('jobs.comments_workers', 'number', 'Comments job', 'PRs addressed at once', 'How many pull requests one comments run addresses at the same time, each in its own session. A schedule given --workers uses its own number instead. Unset, 1: one PR after another.', { min: 1, max: 16, placeholder: '1' }),
  field('jobs.comments.max_failures', 'number', 'Comments job', 'Failed passes before a PR is dropped', 'How many failed passes in a row on one pull request before the comments job stops trying it and tells you. Unset, 3.', { min: 1, max: 20, placeholder: '3' }),
  field('intake.notes', 'string', 'Intake job', 'Notes file', `The notes file the intake job turns into tracker items. ${INTAKE_PATH} The file need not exist yet: with no file there the job says "no notes file" and stops quietly. Unset, the job stops with an error unless its schedule names a notes file.`, { placeholder: '.flow/notes.md' }),
  field('intake.batch', 'number', 'Intake job', 'Notes per intake run', 'How many notes one intake run files at most. Unset, 10.', { min: 1, max: 100, placeholder: '10' }),
  field('intake.rules', 'string', 'Intake job', 'Intake rules file', `The file that says how a note becomes an item: outcomes, type, area, priority. ${INTAKE_PATH} It must exist; unset, .flow/intake.md when there is one, else the flow's own rules.`, { placeholder: '.flow/intake.md' }),
  field('intake.answers', 'string', 'Intake job', 'Answers file', `Where the intake job appends the answers it gave. ${INTAKE_PATH} Empty puts answers.md beside the notes.`, { placeholder: '.flow/answers.md' }),
  field('intake.dropped', 'string', 'Intake job', 'Dropped notes file', `Where the intake job moves the notes it dropped, with the reason. ${INTAKE_PATH} Empty puts dropped.md beside the notes.`, { placeholder: '.flow/dropped.md' }),
  field('intake.commit', 'boolean', 'Intake job', 'Commit the notes file', 'When off, the intake job leaves the notes file uncommitted after filing.'),
];

/**
 * The field of a named schedule, `jobs.schedule.<job>-<label>`: the file may hold any number of
 * them, so the schema lists none and makes each one here; undefined for any other path.
 */
function namedScheduleField(path: string): FieldSpec | undefined {
  if (!path.startsWith(SCHEDULE_PREFIX)) return undefined;
  const name = path.slice(SCHEDULE_PREFIX.length);
  if (!SCHEDULE_NAME.test(name) || JOBS.includes(name)) return undefined;
  return field(path, 'schedule', 'Schedules', `${capitalised(name)} schedule`, `Another schedule of the ${scheduleJob(name)} job, ${name}, with its own timing and options.`, { followUp: RELOAD_SCHEDULE });
}

export function fieldAt(path: string): FieldSpec | undefined {
  return FLOW_CONFIG_SCHEMA.find((spec) => spec.path === path) ?? namedScheduleField(path) ?? pickField(path);
}

/** The schema field a path belongs to: itself, the map or list field above it, or the field whose plain list it is. */
export function fieldCovering(path: string): FieldSpec | undefined {
  return FLOW_CONFIG_SCHEMA.find((spec) => spec.path === path || spec.plainList === path || ((spec.type === 'map' || spec.type === 'list') && path.startsWith(`${spec.path}.`))) ?? namedScheduleField(path) ?? pickField(path);
}

/** The plain list a field stands for, as the parsed file holds it (a list, or one item), or undefined when its key holds a map or nothing. */
export function plainListValue(values: Record<string, unknown>, spec: FieldSpec): string | unknown[] | undefined {
  if (spec.plainList === undefined) return undefined;
  let current: unknown = values;
  for (const key of spec.plainList.split('.')) {
    if (current === null || typeof current !== 'object' || Array.isArray(current)) return undefined;
    current = (current as Record<string, unknown>)[key];
  }
  return Array.isArray(current) || (typeof current === 'string' && current !== '') ? current : undefined;
}

/** The fields of the named schedules a parsed file holds, in file order. */
export function namedScheduleFields(values: Record<string, unknown>): FieldSpec[] {
  const jobs = values['jobs'];
  const schedule = jobs !== null && typeof jobs === 'object' && !Array.isArray(jobs) ? (jobs as Record<string, unknown>)['schedule'] : undefined;
  if (schedule === null || typeof schedule !== 'object' || Array.isArray(schedule)) return [];
  return Object.keys(schedule).flatMap((name) => namedScheduleField(`${SCHEDULE_PREFIX}${name}`) ?? []);
}

const PICK_PREFIX = 'pick.';
/** A filter's name, as flow's pick_check in lib/flow.sh takes it. */
const PICK_NAME = /^[A-Za-z0-9_-]+$/;
const PICK_KINDS = ['epic', 'task', 'bug'];
/**
 * The fields of a pick filter, `pick.<name>.<field>`, in the order the form shows them: what each
 * keeps, as flow's adapters map it (adapters/README.md, Pick filters).
 */
const PICK_FIELDS: { name: string; type: FieldType; label: string; help: string; extra: Partial<FieldSpec> }[] = [
  { name: 'assignee', type: 'string', label: 'Assignee', help: 'Keeps the items assigned to this person: me (the user the tracker acts as), a login or an email.', extra: { placeholder: 'me' } },
  { name: 'status', type: 'list', label: 'Statuses', help: 'Keeps the items in one of these statuses, as the tracker names them.', extra: { placeholder: 'To Do' } },
  { name: 'labels', type: 'list', label: 'Labels', help: 'Keeps the items with one of these labels.', extra: { placeholder: 'api' } },
  { name: 'kinds', type: 'list', label: 'Kinds', help: 'Keeps the items of one of these kinds.', extra: { values: PICK_KINDS } },
  { name: 'trackers', type: 'list', label: 'Trackers', help: 'The trackers the filter reads; empty, every tracker the flow reads.', extra: { values: ADAPTERS } },
  { name: 'query', type: 'string', label: 'Query', help: 'One tracker\'s own search, passed as written (JQL on Jira, search qualifiers on GitHub): set Trackers to that one tracker and leave the other fields empty.', extra: { placeholder: 'component = Backend' } },
];

/**
 * The field of a pick filter's key, `pick.<name>.<field>`: next --pick <name> and a next schedule
 * with --pick take only the ready items it keeps. The file may name any filters, so the schema
 * lists none and makes each one here, in Readiness under the filter's own name; undefined for any
 * other path.
 */
function pickField(path: string): FieldSpec | undefined {
  if (!path.startsWith(PICK_PREFIX)) return undefined;
  const [name = '', key = '', ...rest] = path.slice(PICK_PREFIX.length).split('.');
  const known = PICK_FIELDS.find((each) => each.name === key);
  if (!PICK_NAME.test(name) || known === undefined || (rest.length > 0 && known.type !== 'list')) return undefined;
  return field(`${PICK_PREFIX}${name}.${key}`, known.type, 'Readiness', known.label, known.help, { ...known.extra, part: `Pick filter ${name}`, emptyUnset: true });
}

/** The fields of every pick filter a parsed file holds, each filter's in the form's order, filters in file order. */
export function pickFields(values: Record<string, unknown>): FieldSpec[] {
  const picks = values['pick'];
  if (picks === null || typeof picks !== 'object' || Array.isArray(picks)) return [];
  return Object.keys(picks).flatMap((name) => PICK_FIELDS.flatMap((each) => pickField(`${PICK_PREFIX}${name}.${each.name}`) ?? []));
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
/** HH:MM, two digits each, as `_jobs.py clock` reads it. */
const CLOCK = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
/**
 * One option or value after the schedule, as `_jobs.py`'s ARG takes it: no spaces, quotes, globs,
 * redirections or substitutions. `#` is in it so an item id (gh#12) can be one.
 */
const SCHEDULE_ARG = /^[A-Za-z0-9_./:=@%+,#-]+$/;
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
  if (bad !== undefined) return fail(`the schedule "${text}" has the arg "${bad}": an arg is one option or value of letters, digits and _./:=@%+,#-`);
  // The schedule lives in .flow/config.yaml, where lib/flow.sh reads " #" as the start of a comment.
  const comment = args.find((arg) => arg.startsWith('#'));
  return comment === undefined ? ok : fail(`the schedule "${text}" has the arg "${comment}": an arg cannot open with #, which .flow/config.yaml reads as a comment`);
}

/**
 * A map written on one line, `{claude: 1, codex: 2}`, as the plugin's `_jobs.py workers` reads it:
 * the entries between the braces split on commas, each `name: value` with quotes taken off; null
 * when the text is not in braces or an entry has no colon.
 */
export function parseOneLineMap(text: string): Record<string, string> | null {
  const raw = text.trim();
  if (!raw.startsWith('{') || !raw.endsWith('}')) return null;
  const unquote = (part: string): string => part.trim().replace(/^["']+|["']+$/g, '');
  const entries: Record<string, string> = {};
  for (const part of raw.slice(1, -1).split(',')) {
    if (part.trim() === '') continue;
    const colon = part.indexOf(':');
    if (colon < 0) return null;
    entries[unquote(part.slice(0, colon))] = unquote(part.slice(colon + 1));
  }
  return entries;
}

/** A counts map's entries against its names and range, as `_jobs.py workers` checks `jobs.workers`. */
function checkCounts(spec: FieldSpec & { counts: { keys: string[] } }, entries: Record<string, string>): Checked {
  for (const [key, value] of Object.entries(entries)) {
    if (!spec.counts.keys.includes(key)) return fail(`${spec.path} names ${key}: it takes ${spec.counts.keys.join(' and ')}`);
    if (!/^[0-9]+$/.test(value)) return fail(`${spec.path}.${key} must be a whole number, not "${value}"`);
    const checked = inRange({ ...spec, path: `${spec.path}.${key}` }, Number(value));
    if (!checked.ok) return checked;
  }
  const values = Object.values(entries);
  return values.length > 0 && values.every((value) => Number(value) === 0) ? fail(`${spec.path} starts no worker: give one of ${spec.counts.keys.join(', ')} 1 or more`) : ok;
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
    case 'enumOrText': return ok;
    case 'duration': return DURATION.test(text) ? ok : fail(`${spec.path} must be a number with s, m, h or d, like 10m or 24h, not "${text}"`);
    case 'schedule': { const checked = checkSchedule(text); return checked.ok ? ok : fail(`${spec.path}: ${checked.error}`); }
    case 'list': return ok;
    case 'map': return fail(`${spec.path} must be a map of name: value lines, not "${text}"`);
  }
}

/** A list with fixed values (`ready.needs`) holds only those; an empty or free list passes. */
function checkListValues(spec: FieldSpec, entries: string[]): Checked {
  if (spec.values === undefined) return ok;
  const other = entries.find((entry) => !spec.values!.includes(entry));
  return other === undefined ? ok : fail(`${spec.path} lists ${other}: it takes ${saidList(spec.values)}`);
}

/** A map under fixed names (`github.status`) names only those. */
function checkMapKeys(spec: FieldSpec, entries: Record<string, unknown>): Checked {
  if (spec.keys === undefined) return ok;
  const names = spec.keys.map((key) => key.name);
  const other = Object.keys(entries).find((name) => !names.includes(name));
  return other === undefined ? ok : fail(`${spec.path} names ${other}: it takes ${saidList(names)}`);
}

/**
 * A value read from the file against its field. A list may be written as one scalar (the flow
 * reads it as a one-item list); a map whose entries are maps themselves (a gate with command and
 * paths) passes too, and is edited as raw YAML.
 */
export function checkFileValue(spec: FieldSpec, value: unknown): Checked {
  if (spec.type === 'list') {
    if (typeof value === 'string') return value === '' ? ok : checkListValues(spec, [value]);
    // A bare key with no items is how the flat format writes an empty list.
    if (value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0) return ok;
    return Array.isArray(value) && value.every((entry) => typeof entry === 'string') ? checkListValues(spec, value) : fail(`${spec.path} must be a list of text`);
  }
  if (spec.type === 'map') {
    if (spec.counts !== undefined) return checkCountsValue({ ...spec, counts: spec.counts }, value);
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) return checkMapKeys(spec, value as Record<string, unknown>);
    return fail(`${spec.path} must be a map of name: value lines`);
  }
  if (typeof value !== 'string') return fail(`${spec.path} must be one value, not a ${Array.isArray(value) ? 'list' : 'map'}`);
  return checkText(spec, value);
}

/** A counts map as the file holds it: one line in braces, or name: value lines under the key. */
function checkCountsValue(spec: FieldSpec & { counts: { keys: string[] } }, value: unknown): Checked {
  if (typeof value === 'string') {
    if (value.trim() === '') return ok;
    const entries = parseOneLineMap(value);
    return entries === null ? fail(`${spec.path} is "${value}": write it as {${spec.counts.keys.map((key, index) => `${key}: ${index + 1}`).join(', ')}}, or one name per line under it`) : checkCounts(spec, entries);
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return fail(`${spec.path} must be a map of name: count lines`);
  const entries = value as Record<string, unknown>;
  const notText = Object.keys(entries).find((key) => typeof entries[key] !== 'string');
  if (notText !== undefined) return fail(`${spec.path}.${notText} must be one count, not a list or a map`);
  return checkCounts(spec, entries as Record<string, string>);
}

/** A change from the UI against its field: the JSON type the field takes, then the same checks as a value in the file. */
export function checkChange(spec: FieldSpec, value: FieldValue): Checked {
  if (value === null) return ok;
  switch (spec.type) {
    case 'number':
      if (typeof value !== 'number' || !Number.isInteger(value)) return fail(`${spec.path} must be a whole number`);
      return inRange(spec, value);
    case 'boolean': return typeof value === 'boolean' ? ok : fail(`${spec.path} must be true or false`);
    case 'list': return Array.isArray(value) && value.every((entry) => typeof entry === 'string') ? checkListValues(spec, value) : fail(`${spec.path} must be a list of text`);
    case 'map': {
      const map = value !== null && typeof value === 'object' && !Array.isArray(value) && Object.entries(value).every(([key, entry]) => /^[A-Za-z0-9_-]+$/.test(key) && typeof entry === 'string');
      if (!map) return fail(`${spec.path} must be a map of names (letters, digits, - and _) to text`);
      if (spec.keys !== undefined) return checkMapKeys(spec, value as Record<string, string>);
      return spec.counts === undefined ? ok : checkCounts({ ...spec, counts: spec.counts }, value as Record<string, string>);
    }
    case 'string': case 'enum': case 'enumOrText': case 'duration': case 'schedule':
      return typeof value === 'string' ? checkText(spec, value) : fail(`${spec.path} must be text`);
  }
}
