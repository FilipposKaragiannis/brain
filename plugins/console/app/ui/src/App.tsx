import { useCallback, useEffect, useRef, useState } from 'react';
import type { Snapshot } from '../../daemon/src/snapshot.ts';
import { isActive } from './actions.ts';
import { ActionsDrawer } from './ActionsDrawer.tsx';
import { DAEMON_RETRY_MS, unreachableMessage } from './api.ts';
import { useServices } from './console.tsx';
import { clockTime, useNow } from './clock.tsx';
import { parseRoute, routeHash, SCREENS, screenLabel, SETTINGS_HASH } from './route.ts';
import type { Route, Screen } from './route.ts';
import { ProjectHeader } from './ProjectHeader.tsx';
import { Activity } from './screens/Activity.tsx';
import { Agents } from './screens/Agents.tsx';
import { Gates, GatesHeading } from './screens/Gates.tsx';
import { Overview } from './screens/Overview.tsx';
import { Pulls } from './screens/Pulls.tsx';
import { Settings } from './screens/Settings.tsx';
import { Worktrees } from './screens/Worktrees.tsx';
import { ThemeToggle } from './theme.tsx';
import { ActionsProvider, Dot, Empty } from './ui.tsx';
import { useActions } from './useActions.ts';
import { HTTP_OK, useProject } from './useProject.ts';
import type { LinkState, ProjectSummary } from './stream.ts';

/** The project list, or why it could not be read. */
type ProjectList = { kind: 'loading' } | { kind: 'listed'; projects: ProjectSummary[] } | { kind: 'unreachable'; message: string };

export const PROJECTS_RETRY_MS = DAEMON_RETRY_MS;

export function App() {
  const route = useRoute();
  const list = useProjects();
  if (list.kind === 'loading') return <div className="boot"><Empty>Connecting to the daemon…</Empty></div>;
  if (list.kind === 'unreachable') return <div className="boot"><Empty>{list.message}. Trying again every {PROJECTS_RETRY_MS / MILLISECONDS_PER_SECOND} s.</Empty></div>;
  return <Listed route={route} projects={list.projects} />;
}

const MILLISECONDS_PER_SECOND = 1000;

function Listed({ route, projects }: { route: Route; projects: ProjectSummary[] }) {
  // Settings belong to the daemon, not a project: the page keeps the project it came from around them.
  const lastProject = useRef<string | null>(null);
  const settings = route.screen === 'settings';
  const remembered = projects.some((project) => project.id === lastProject.current) ? lastProject.current : null;
  const projectId = route.projectId ?? (settings ? remembered : null) ?? projects[0]?.id ?? null;
  if (!settings) lastProject.current = projectId;
  useEffect(() => {
    if (!settings && route.projectId === null && projectId !== null) window.location.replace(routeHash({ ...route, projectId }));
  }, [route, projectId, settings]);
  if (projectId === null) return <div className="boot">{settings ? <Settings /> : <Empty>The daemon watches no project. <a href={SETTINGS_HASH}>Settings</a></Empty>}</div>;
  if (!projects.some((project) => project.id === projectId)) {
    return (
      <div className="boot">
        <Empty>No project {projectId}.</Empty>
        <ProjectSwitcher projects={projects} value="" onPick={(id) => { window.location.hash = routeHash({ projectId: id, screen: route.screen, detail: null }); }} />
      </div>
    );
  }
  return <ProjectShell key={projectId} route={{ ...route, projectId }} projectId={projectId} projects={projects} />;
}

function ProjectSwitcher({ projects, value, onPick }: { projects: ProjectSummary[]; value: string; onPick: (projectId: string) => void }) {
  return (
    <select className="project-switcher" aria-label="Project" value={value} onChange={(event) => onPick(event.target.value)}>
      {value === '' && <option value="" disabled>Pick a project</option>}
      {projects.map((project) => <option key={project.id} value={project.id}>{project.name}</option>)}
    </select>
  );
}

function ProjectShell({ route, projectId, projects }: { route: Route; projectId: string; projects: ProjectSummary[] }) {
  const { snapshot, link } = useProject(projectId);
  const actions = useActions(projectId);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const closeDrawer = useCallback(() => setDrawerOpen(false), []);
  const go = (next: Route): void => { window.location.hash = routeHash(next); };
  const running = actions.records.filter((record) => isActive(record.state)).length;
  return (
    <ActionsProvider actions={actions}>
      <div className="shell">
        <nav className="nav" aria-label="Main">
          <div className="brand"><span className="brand-mark">B</span>Brain Console</div>
          <ProjectSwitcher projects={projects} value={projectId} onPick={(id) => go({ projectId: id, screen: route.screen === 'settings' ? 'overview' : route.screen, detail: null })} />
          {SCREENS.map((entry) => (
            <a key={entry.screen} className={entry.screen === route.screen ? 'nav-link active' : 'nav-link'} href={routeHash({ projectId, screen: entry.screen, detail: null })}>
              <span>{entry.label}</span>{snapshot !== null && <NavBadge screen={entry.screen} snapshot={snapshot} />}
            </a>
          ))}
          <div className="nav-foot">
            <LinkStatus link={link} />
          </div>
        </nav>
        <main className="main">
          {snapshot !== null && <ProjectHeader project={snapshot.project} />}
          <header className="page-head">
            <div className="page-title"><h1>{screenLabel(route.screen)}</h1>{route.screen === 'gates' && snapshot !== null && <GatesHeading snapshot={snapshot} />}</div>
            <div className="page-tools">
              <a className={route.screen === 'settings' ? 'button active' : 'button'} href={SETTINGS_HASH}>Settings</a>
              <button type="button" className="button" onClick={() => setDrawerOpen((open) => !open)}>Actions{running > 0 ? ` · ${running} running` : ''}</button>
              <ThemeToggle />
              <WallClock />
            </div>
          </header>
          {route.screen === 'settings' ? <Settings /> : snapshot === null ? <Empty>Waiting for the first snapshot…</Empty> : <ScreenView route={route} snapshot={snapshot} go={go} />}
        </main>
        {drawerOpen && <ActionsDrawer actions={actions} close={closeDrawer} />}
      </div>
    </ActionsProvider>
  );
}

function ScreenView({ route, snapshot, go }: { route: Route; snapshot: Snapshot; go: (route: Route) => void }) {
  switch (route.screen) {
    case 'overview': return <Overview snapshot={snapshot} go={go} />;
    case 'gates': return <Gates snapshot={snapshot} selected={route.detail} />;
    case 'worktrees': return <Worktrees snapshot={snapshot} />;
    case 'agents': return <Agents snapshot={snapshot} />;
    case 'pulls': return <Pulls snapshot={snapshot} />;
    case 'activity': return <Activity key={route.detail ?? ''} snapshot={snapshot} item={route.detail} go={go} />;
    case 'settings': return <Settings />;
  }
}

function NavBadge({ screen, snapshot }: { screen: Screen; snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  switch (screen) {
    case 'gates': return snapshot.gates.length > 0 ? <span className="badge tone-needs-you">{snapshot.gates.length}</span> : null;
    case 'worktrees': return <span className="badge-plain">{pool.filter((worktree) => worktree.claim !== null).length} / {pool.length}</span>;
    case 'agents': return snapshot.counts.agents > 0 ? <span className="badge-plain tone-running"><Dot tone="running" />{snapshot.counts.agents} live</span> : null;
    case 'overview': case 'pulls': case 'activity': case 'settings': return null;
  }
}

function LinkStatus({ link }: { link: LinkState }) {
  if (link === 'open') return <span className="link-status"><Dot tone="running" />live</span>;
  if (link === 'down') return <span className="link-status"><Dot tone="failing" />stream down, polling every 30 s</span>;
  return <span className="link-status"><Dot tone="quiet" />connecting…</span>;
}

function WallClock() {
  const now = useNow();
  const moment = new Date(now);
  return <span className="wall-clock mono">{clockTime(moment.toISOString())}:{String(moment.getSeconds()).padStart(2, '0')}</span>;
}

function useRoute(): Route {
  const [hash, setHash] = useState(() => window.location.hash);
  useEffect(() => {
    const changed = (): void => setHash(window.location.hash);
    window.addEventListener('hashchange', changed);
    return () => window.removeEventListener('hashchange', changed);
  }, []);
  return parseRoute(hash);
}

/** The project list: read at start (and again until the daemon answers), then kept by the `projects` event when Settings change it. */
function useProjects(): ProjectList {
  const { api, hub } = useServices();
  const [list, setList] = useState<ProjectList>({ kind: 'loading' });
  useEffect(() => hub.onProjects((projects) => setList({ kind: 'listed', projects })), [hub]);
  useEffect(() => {
    let cancelled = false;
    let retry: ReturnType<typeof setTimeout> | null = null;
    const read = async (): Promise<void> => {
      const response = await api.request('/api/projects', 'GET', null);
      if (cancelled) return;
      if (response.status === HTTP_OK && Array.isArray(response.body)) { setList({ kind: 'listed', projects: response.body as ProjectSummary[] }); return; }
      setList({ kind: 'unreachable', message: unreachableMessage(response.status) });
      retry = setTimeout(() => { void read(); }, PROJECTS_RETRY_MS);
    };
    void read();
    return () => { cancelled = true; if (retry !== null) clearTimeout(retry); };
  }, [api]);
  return list;
}
