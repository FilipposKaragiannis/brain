import type { ReactNode } from 'react';
import { Fragment, useCallback, useEffect, useState } from 'react';
import type { FieldGroup, GroupFamily } from '../../../daemon/src/plugins/flow/schema.ts';
import { FIELD_GROUPS, GROUP_FAMILY } from '../../../daemon/src/plugins/flow/schema.ts';
import type { SettingOrigin, SettingsView, TerminalName, TerminalSetting } from '../../../daemon/src/snapshot.ts';
import { unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import type { ProjectSummary } from '../stream.ts';
import { Empty, Module } from '../ui.tsx';
import { OpenFileButton } from '../OpenFileButton.tsx';
import { AddProject } from './AddProject.tsx';
import type { FlowShown } from './FlowSettings.tsx';
import { FlowSettings } from './FlowSettings.tsx';
import { HTTP_OK } from '../useProject.ts';

export const SETTINGS_PATH = '/api/settings';

const TERMINAL_LABELS: Record<TerminalName, string> = { iterm: 'iTerm', terminal: 'Terminal', ghostty: 'Ghostty' };
const TERMINAL_ORDER: TerminalName[] = ['iterm', 'terminal', 'ghostty'];
const MAX_PORT = 65535;
const ORIGIN_WORDS: Record<SettingOrigin, string> = { flag: 'set by a start flag', environment: 'set by the environment', file: 'from the config file', default: 'the default' };

type Read = { kind: 'loading' } | { kind: 'read'; view: SettingsView } | { kind: 'unreachable'; message: string };
/** The terminal radio: a named app, the first one installed, or the owner's own command. */
type Choice = TerminalName | 'auto' | 'custom';

function choiceOf(value: TerminalSetting | null): Choice {
  if (value === null) return 'auto';
  return typeof value === 'string' ? value : 'custom';
}

/**
 * A custom command as typed: a JSON array of strings, so a word may hold a space (an app path
 * such as "/Applications/My Term.app"). Returns the words, or why the text is not one.
 */
export function parseCommand(text: string): { ok: true; words: string[] } | { ok: false; error: string } {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return { ok: false, error: 'write the command as a JSON array, such as ["open", "-a", "Warp", "{path}"]' }; }
  if (!Array.isArray(parsed) || parsed.length === 0 || !parsed.every((word) => typeof word === 'string' && word !== '')) {
    return { ok: false, error: 'the command must be a JSON array of non-empty strings' };
  }
  return { ok: true, words: parsed as string[] };
}

/**
 * The pages of the menu: the console's General and Projects, one project's flow settings by
 * group, and Configuration, which holds the jobs' own groups one tab at a time.
 */
type Page = { kind: 'general' } | { kind: 'projects' } | { kind: 'flow'; group: FieldGroup } | { kind: 'configuration' };
const familyPages = (family: GroupFamily): FieldGroup[] => FIELD_GROUPS.filter((group) => GROUP_FAMILY[group] === family);
const FLOW_PAGES = familyPages('Flow');
const SCHEDULES_PAGE: FieldGroup = 'Schedules';
/** The jobs' own groups (Next job, Health job, …): the tabs of Configuration. */
const JOB_TABS = familyPages('Jobs').filter((group) => group !== SCHEDULES_PAGE);
const AGENT_PAGES = familyPages('Agents');
/** A job tab's label: the job's name, "Next" for Next job. */
export const jobTabLabel = (group: FieldGroup): string => group.replace(/ job$/, '');

function samePage(left: Page, right: Page): boolean {
  if (left.kind === 'flow' && right.kind === 'flow') return left.group === right.group;
  return left.kind === right.kind;
}

/** The menu's expandable groups: Plugins, Flow inside it, and Jobs. */
type MenuGroup = 'plugins' | 'flow' | 'jobs';
const MENU_GROUPS: MenuGroup[] = ['plugins', 'flow', 'jobs'];
export const MENU_STORAGE_KEY = 'console.settings.closedGroups';

/** Whether a menu group holds the page: the group stays open while its page shows. */
function holds(group: MenuGroup, page: Page): boolean {
  const flowPage = page.kind === 'flow' && FLOW_PAGES.includes(page.group);
  if (group === 'plugins' || group === 'flow') return flowPage;
  return page.kind === 'configuration' || (page.kind === 'flow' && page.group === SCHEDULES_PAGE);
}

/** The groups this browser closed last; all open when nothing is kept or storage is blocked. */
function storedClosed(): MenuGroup[] {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(MENU_STORAGE_KEY) ?? '[]');
    return Array.isArray(parsed) ? MENU_GROUPS.filter((group) => parsed.includes(group)) : [];
  } catch {
    return [];
  }
}

function storeClosed(closed: MenuGroup[]): void {
  try {
    window.localStorage.setItem(MENU_STORAGE_KEY, JSON.stringify(closed));
  } catch {
    // The menu still opens and closes; it is only not remembered.
  }
}

/**
 * The daemon's settings and the watched projects' flow settings, one page at a time beside a menu:
 * General (the terminal, the daemon, the files and each project's raw YAML), Projects (watched,
 * removed, and added step by step), then the expandable groups Plugins (with Flow inside) and
 * Jobs (Schedules, and Configuration with one tab per job), then Agents, each for the project the
 * picker names (no picker with one project). A group's open or closed state is kept per browser;
 * the group holding the page on screen stays open. Every project's flow settings stay mounted,
 * so a draft survives moving between pages and job tabs. Every console change is one PUT; the
 * daemon checks it whole and says why when it refuses.
 */
export function Settings() {
  const { api } = useServices();
  const [read, setRead] = useState<Read>({ kind: 'loading' });
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [page, setPage] = useState<Page>({ kind: 'general' });
  const [job, setJob] = useState<FieldGroup>(JOB_TABS[0]!);
  const [closed, setClosed] = useState<MenuGroup[]>(storedClosed);
  const [scope, setScope] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const readProjects = useCallback(async (): Promise<void> => {
    const response = await api.request('/api/projects', 'GET', null);
    if (response.status === HTTP_OK && Array.isArray(response.body)) setProjects(response.body as ProjectSummary[]);
  }, [api]);

  useEffect(() => {
    let cancelled = false;
    void api.request(SETTINGS_PATH, 'GET', null).then((response) => {
      if (cancelled) return;
      setRead(response.status === HTTP_OK && response.body !== null ? { kind: 'read', view: response.body as SettingsView } : { kind: 'unreachable', message: unreachableMessage(response.status) });
    });
    void api.request('/api/projects', 'GET', null).then((response) => {
      if (!cancelled && response.status === HTTP_OK && Array.isArray(response.body)) setProjects(response.body as ProjectSummary[]);
    });
    return () => { cancelled = true; };
  }, [api]);

  const save = useCallback(async (change: Record<string, unknown>): Promise<boolean> => {
    setSaving(true);
    const response = await api.request(SETTINGS_PATH, 'PUT', change);
    setSaving(false);
    if (response.status === HTTP_OK && response.body !== null) {
      setRead({ kind: 'read', view: response.body as SettingsView });
      setError(null);
      if (change['projects'] !== undefined) await readProjects();
      return true;
    }
    const message = (response.body as { error?: unknown } | null)?.error;
    setError(typeof message === 'string' ? message : unreachableMessage(response.status));
    return false;
  }, [api, readProjects]);

  if (read.kind === 'loading') return <Empty>Reading the settings…</Empty>;
  if (read.kind === 'unreachable') return <Empty>{read.message}.</Empty>;
  const { view } = read;
  const scoped = projects.find((project) => project.id === scope) ?? projects[0] ?? null;
  const link = (target: Page, label: string) => (
    <li key={label}><button type="button" className={samePage(page, target) ? 'settings-link active' : 'settings-link'} aria-current={samePage(page, target) ? 'page' : undefined} onClick={() => setPage(target)}>{label}</button></li>
  );
  const groupLinks = (groups: FieldGroup[]) => <ul>{groups.map((group) => link({ kind: 'flow', group }, group))}</ul>;
  const toggle = (group: MenuGroup): void => {
    const next = closed.includes(group) ? closed.filter((other) => other !== group) : [...closed, group];
    setClosed(next);
    storeClosed(next);
  };
  const menuGroup = (group: MenuGroup, label: string, sub: boolean, children: ReactNode) => {
    const pinned = holds(group, page);
    const open = pinned || !closed.includes(group);
    const id = `settings-group-${group}`;
    const Head = sub ? 'h4' : 'h3';
    return (
      <div className={sub ? 'settings-group sub' : 'settings-group'}>
        <Head className={sub ? 'settings-nav-sub' : 'settings-nav-head'}>
          <button type="button" className="settings-group-toggle" aria-expanded={open} aria-controls={id} disabled={pinned}
            title={pinned ? 'Holds the page on screen' : undefined} onClick={() => toggle(group)}>
            <span className="settings-chevron" aria-hidden="true" />{label}
          </button>
        </Head>
        <div id={id} className="settings-group-body" hidden={!open}>{children}</div>
      </div>
    );
  };
  const shown = (projectId: string): FlowShown => {
    if (projectId !== scoped?.id) return page.kind === 'general' ? 'raw' : null;
    if (page.kind === 'flow') return page.group;
    if (page.kind === 'configuration') return job;
    return page.kind === 'general' ? 'raw' : null;
  };
  return (
    <div className="screen settings">
      {error !== null && <p className="banner tone-failing" role="alert">Not saved: {error}</p>}
      <div className="settings-layout">
        <nav className="settings-nav" aria-label="Settings sections">
          {projects.length > 1 && (
            <label className="settings-scope">
              <span className="settings-nav-head">Project</span>
              <select className="input" aria-label="Project for Plugins, Jobs and Agents" value={scoped?.id ?? ''} onChange={(event) => setScope(event.target.value)}>
                {projects.map((project) => <option key={project.id} value={project.id}>{project.name}</option>)}
              </select>
            </label>
          )}
          <ul>{link({ kind: 'general' }, 'General')}{link({ kind: 'projects' }, 'Projects')}</ul>
          {scoped !== null && (
            <>
              {menuGroup('plugins', 'Plugins', false, menuGroup('flow', 'Flow', true, groupLinks(FLOW_PAGES)))}
              {menuGroup('jobs', 'Jobs', false, <ul>{link({ kind: 'flow', group: SCHEDULES_PAGE }, SCHEDULES_PAGE)}{link({ kind: 'configuration' }, 'Configuration')}</ul>)}
              <hr className="settings-nav-rule" />
              {groupLinks(AGENT_PAGES)}
            </>
          )}
        </nav>
        <div className="settings-part">
          {page.kind === 'general' && <General view={view} projects={projects} saving={saving} save={save} />}
          {page.kind === 'projects' && (
            <Module className="settings-projects" title="Projects" aside={<span className="muted">{ORIGIN_WORDS[view.projects.from]}</span>} footer={null}>
              <Projects view={view} saving={saving} save={save} />
            </Module>
          )}
          {page.kind === 'configuration' && scoped !== null && <JobTabs job={job} choose={setJob} />}
          {projects.map((project) => <FlowSettings key={project.id} projectId={project.id} name={project.name} show={shown(project.id)} />)}
        </div>
      </div>
    </div>
  );
}

/**
 * Configuration's trail: "Configuration ›" then one button per job, the chosen one current. Only
 * the chosen job's settings show; the others stay mounted, so their drafts wait.
 */
function JobTabs({ job, choose }: { job: FieldGroup; choose: (group: FieldGroup) => void }) {
  return (
    <nav className="settings-crumbs" aria-label="Job configuration">
      <span className="settings-crumb-root">Configuration</span>
      <span className="settings-crumb-sep" aria-hidden="true">›</span>
      <div className="settings-crumb-jobs" role="group" aria-label="Jobs">
        {JOB_TABS.map((group) => (
          <button key={group} type="button" className={group === job ? 'settings-crumb active' : 'settings-crumb'} aria-current={group === job ? 'true' : undefined}
            title={group} onClick={() => choose(group)}>{jobTabLabel(group)}</button>
        ))}
      </div>
    </nav>
  );
}

/** The settings that are no one plugin's or job's: the terminal, the daemon, and the files (each project's raw YAML follows). */
function General({ view, projects, saving, save }: PartProps & { projects: ProjectSummary[] }) {
  return (
    <>
      <Module className="settings-terminal" title="Terminal" aside={<span className="muted">{ORIGIN_WORDS[view.terminal.from]}</span>} footer={null}>
        <Terminal view={view} saving={saving} save={save} />
      </Module>
      <Module className="settings-daemon" title="Daemon" aside={null} footer={null}>
        <Daemon view={view} saving={saving} save={save} />
      </Module>
      <Files view={view} projects={projects} />
    </>
  );
}

type PartProps = { view: SettingsView; saving: boolean; save: (change: Record<string, unknown>) => Promise<boolean> };

/** The port, which takes effect at the next start, and how the daemon runs. */
function Daemon({ view, saving, save }: PartProps) {
  const [port, setPort] = useState(String(view.port.saved ?? view.port.value));
  const number = Number(port);
  const valid = Number.isInteger(number) && number > 0 && number <= MAX_PORT;
  const unchanged = number === (view.port.saved ?? view.port.value);
  return (
    <dl className="settings-facts">
      <dt>Port</dt>
      <dd>
        <span className="mono">{view.port.value}</span> <span className="muted">now, {ORIGIN_WORDS[view.port.from]}</span>
        <form className="settings-add settings-port" onSubmit={(event) => { event.preventDefault(); if (valid) void save({ port: number }); }}>
          <input aria-label="Port for the next start" className="input mono" inputMode="numeric" value={port} onChange={(event) => setPort(event.target.value)} aria-invalid={!valid} />
          <button type="submit" className="button primary" disabled={saving || !valid || unchanged}>Save for the next start</button>
        </form>
        <p className="module-help">{view.port.note}</p>
      </dd>
      <dt>Runs under</dt><dd>{view.launchd ? 'launchd: it starts on login and comes back after a crash.' : <>a terminal: it stops when that terminal does. <span className="mono">npm run daemon:install</span> in <span className="mono">app</span> runs it on login.</>}</dd>
    </dl>
  );
}

/** Where the console and each project keep their settings, each with Show in Finder. */
function Files({ view, projects }: { view: SettingsView; projects: ProjectSummary[] }) {
  return (
    <Module className="settings-files" title="Files" aside={null} footer={null}>
      <dl className="settings-facts">
        <dt>Console settings</dt>
        <dd className="settings-file"><span className="mono" title={view.configFile}>{view.configFile}</span> <OpenFileButton path={view.configFile} with="finder" label="Show in Finder" /></dd>
        {view.readFromLegacyFile !== null && <><dt>Projects read from</dt><dd><span className="mono">{view.readFromLegacyFile}</span> <span className="muted">(config.json is absent; the first save writes it)</span></dd></>}
        <dt>Console state</dt>
        <dd className="settings-file"><span className="mono" title={view.stateDir}>{view.stateDir}</span> <OpenFileButton path={view.stateDir} with="finder" label="Show in Finder" /> <span className="muted">the audit log, the action output and the token</span></dd>
        {projects.map((project) => {
          const file = `${project.root}/.flow/config.yaml`;
          return <Fragment key={project.id}><dt>{project.name}</dt><dd className="settings-file"><span className="mono" title={file}>{file}</span> <OpenFileButton path={file} with="finder" label="Show in Finder" /> <span className="muted">tracked in the project: commit it there</span></dd></Fragment>;
        })}
      </dl>
    </Module>
  );
}

/** The watched projects, each removable while two or more remain, and Add a project, which walks through the setup. */
function Projects({ view, saving, save }: PartProps) {
  const [adding, setAdding] = useState(false);
  const { roots, editable, note } = view.projects;
  const put = (next: string[]): Promise<boolean> => save({ projects: next.map((entry) => ({ root: entry })) });
  return (
    <>
      {note !== null && <p className="module-help">{note}</p>}
      <ul className="settings-list" aria-label="Watched projects">
        {roots.map((entry) => (
          <li key={entry}>
            <span className="mono">{entry}</span>
            {editable && <button type="button" className="button" disabled={saving || roots.length === 1} title={roots.length === 1 ? 'The daemon watches one project at least' : undefined} onClick={() => { void put(roots.filter((other) => other !== entry)); }}>Remove</button>}
          </li>
        ))}
      </ul>
      {editable && !adding && <div className="settings-add"><button type="button" className="button primary" onClick={() => setAdding(true)}>Add a project</button></div>}
      {editable && adding && <AddProject roots={roots} saving={saving} save={save} close={() => setAdding(false)} />}
    </>
  );
}

function Terminal({ view, saving, save }: PartProps) {
  const current = view.terminal.value;
  const [choice, setChoice] = useState<Choice>(choiceOf(current));
  const [command, setCommand] = useState(typeof current === 'object' && current !== null ? JSON.stringify(current.command) : '');
  const parsed = parseCommand(command);
  const first = view.terminal.installed[0];
  const pick = (next: Choice): void => {
    setChoice(next);
    if (next === 'auto') void save({ terminal: null });
    else if (next !== 'custom') void save({ terminal: next });
  };
  return (
    <fieldset className="settings-terminal-choice" disabled={saving}>
      <legend className="module-help">Open in Terminal opens a folder (or a job's log) in this app.</legend>
      <label><input type="radio" name="terminal" checked={choice === 'auto'} onChange={() => pick('auto')} /> The first installed of iTerm, Ghostty, Terminal {first === undefined ? '(none found)' : `(${TERMINAL_LABELS[first]})`}</label>
      {TERMINAL_ORDER.map((name) => (
        <label key={name}><input type="radio" name="terminal" checked={choice === name} onChange={() => pick(name)} /> {TERMINAL_LABELS[name]}{!view.terminal.installed.includes(name) && <span className="muted"> (not found)</span>}</label>
      ))}
      <label><input type="radio" name="terminal" checked={choice === 'custom'} onChange={() => pick('custom')} /> Custom command</label>
      {choice === 'custom' && (
        <form className="settings-add" onSubmit={(event) => { event.preventDefault(); if (parsed.ok) void save({ terminal: { command: parsed.words } }); }}>
          <input aria-label="Command as a JSON array" className="input mono" placeholder='["open", "-a", "Warp", "{path}"]' value={command} onChange={(event) => setCommand(event.target.value)} aria-invalid={command !== '' && !parsed.ok} />
          <button type="submit" className="button primary" disabled={!parsed.ok}>Save</button>
          {command !== '' && !parsed.ok && <p className="module-help tone-failing" role="status">{parsed.error}</p>}
          <p className="module-help">A JSON array of words, run without a shell. <span className="mono">{'{path}'}</span> is the folder as it is, for a word of its own; inside an <span className="mono">sh -c</span> string use <span className="mono">{'{qpath}'}</span>, the folder quoted for sh, and <span className="mono">{'{cmd}'}</span>, the command to run there (a job's log), quoted already. With neither path the folder goes last.</p>
        </form>
      )}
    </fieldset>
  );
}
