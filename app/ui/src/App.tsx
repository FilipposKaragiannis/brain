import { useEffect, useState } from 'react';
import type { Counts, Snapshot } from '../../daemon/src/snapshot.ts';
import { isActive } from './actions.ts';
import { ActionsDrawer } from './ActionsDrawer.tsx';
import { useServices } from './console.tsx';
import { clockTime, useNow } from './clock.tsx';
import { parseRoute, routeHash, SCREENS } from './route.ts';
import type { Route, Screen } from './route.ts';
import { Agents } from './screens/Agents.tsx';
import { Gates } from './screens/Gates.tsx';
import { Overview } from './screens/Overview.tsx';
import { Pulls } from './screens/Pulls.tsx';
import { Worktrees } from './screens/Worktrees.tsx';
import { ActionsProvider, Dot, Empty } from './ui.tsx';
import { useActions } from './useActions.ts';
import { HTTP_OK, useProject } from './useProject.ts';
import type { LinkState } from './stream.ts';

type ProjectSummary = { id: string; name: string; counts: Counts | null };

export function App() {
  const route = useRoute();
  const projects = useProjects();
  const projectId = route.projectId ?? projects?.[0]?.id ?? null;
  useEffect(() => {
    if (route.projectId === null && projectId !== null) window.location.replace(routeHash({ ...route, projectId }));
  }, [route, projectId]);
  if (projects === null) return <div className="boot"><Empty>Connecting to the daemon…</Empty></div>;
  if (projectId === null) return <div className="boot"><Empty>The daemon watches no project.</Empty></div>;
  return <ProjectShell key={projectId} route={{ ...route, projectId }} projectId={projectId} projects={projects} />;
}

function ProjectShell({ route, projectId, projects }: { route: Route; projectId: string; projects: ProjectSummary[] }) {
  const { snapshot, link } = useProject(projectId);
  const actions = useActions(projectId);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const go = (next: Route): void => { window.location.hash = routeHash(next); };
  const running = actions.records.filter((record) => isActive(record.state)).length;
  return (
    <ActionsProvider actions={actions}>
      <div className="shell">
        <nav className="nav" aria-label="Main">
          <div className="brand"><span className="brand-mark">B</span>Brain Console</div>
          <select className="project-switcher" aria-label="Project" value={projectId} onChange={(event) => go({ projectId: event.target.value, screen: route.screen, detail: null })}>
            {projects.map((project) => <option key={project.id} value={project.id}>{project.name}</option>)}
          </select>
          {SCREENS.map((entry) => (
            <a key={entry.screen} className={entry.screen === route.screen ? 'nav-link active' : 'nav-link'} href={routeHash({ projectId, screen: entry.screen, detail: null })}>
              <span>{entry.label}</span>{snapshot !== null && <NavBadge screen={entry.screen} snapshot={snapshot} />}
            </a>
          ))}
          <div className="nav-foot">
            <LinkStatus link={link} />
            <span>flow {snapshot?.project.pluginVersion ?? '?'}</span>
          </div>
        </nav>
        <main className="main">
          <header className="page-head">
            <h1>{SCREENS.find((entry) => entry.screen === route.screen)?.label}</h1>
            <div className="page-tools">
              <button type="button" className="button" onClick={() => setDrawerOpen((open) => !open)}>Actions{running > 0 ? ` · ${running} running` : ''}</button>
              <WallClock />
            </div>
          </header>
          {snapshot === null ? <Empty>Waiting for the first snapshot…</Empty> : <ScreenView route={route} snapshot={snapshot} go={go} />}
        </main>
        {drawerOpen && <ActionsDrawer actions={actions} close={() => setDrawerOpen(false)} />}
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
  }
}

function NavBadge({ screen, snapshot }: { screen: Screen; snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  switch (screen) {
    case 'gates': return snapshot.gates.length > 0 ? <span className="badge tone-needs-you">{snapshot.gates.length}</span> : null;
    case 'worktrees': return <span className="badge-plain">{pool.filter((worktree) => worktree.claim !== null).length} / {pool.length}</span>;
    case 'agents': return snapshot.counts.agents > 0 ? <span className="badge-plain tone-running"><Dot tone="running" />{snapshot.counts.agents} live</span> : null;
    case 'overview': case 'pulls': return null;
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

function useProjects(): ProjectSummary[] | null {
  const { api } = useServices();
  const [projects, setProjects] = useState<ProjectSummary[] | null>(null);
  useEffect(() => {
    let cancelled = false;
    void api.request('/api/projects', 'GET', null).then((response) => {
      if (cancelled) return;
      setProjects(response.status === HTTP_OK && Array.isArray(response.body) ? (response.body as ProjectSummary[]) : []);
    });
    return () => { cancelled = true; };
  }, [api]);
  return projects;
}
