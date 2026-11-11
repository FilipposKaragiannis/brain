import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { useServices } from './console.tsx';
import type { PaneStore, PaneView } from './panes.ts';
import type { ProjectSummary } from './stream.ts';

/** The dock's accessible name. */
export const PANE_DOCK_NAME = 'Terminal panes';

/** The name of the button that folds the dock to its tabs and opens it again; aria-expanded says which. */
export const PANE_DOCK_TOGGLE = 'Terminals';

const PANE_BODY_ID = 'pane-dock-body';

/** The accessible name of a tab's Close button. */
export function closePaneName(label: string): string {
  return `Close ${label}`;
}

/**
 * The open panes, fixed to the bottom of the page right of the nav, outside the routed screens: a
 * screen change, a project switch or Settings leaves every pane and its screen as it was. One tab
 * per pane with its Close; the newest pane comes forward when it opens. Every pane's surface stays
 * mounted, the inactive ones hidden, so no terminal is torn down while its pane lives.
 */
export function PaneDock({ projectOnScreen, projects }: { projectOnScreen: string | null; projects: readonly ProjectSummary[] }) {
  const { panes: store } = useServices();
  const views = usePaneViews(store);
  const { active, collapsed, choose, toggle } = useDockState(views);
  if (views.length === 0) return null;
  return (
    <section className={collapsed ? 'pane-dock collapsed' : 'pane-dock'} aria-label={PANE_DOCK_NAME}>
      <div className="pane-bar">
        <div className="pane-tabs">
          {views.map((view) => <PaneTab key={view.key} store={store} view={view} label={paneLabel(view, projectOnScreen, projects)} active={view.key === active} choose={choose} />)}
        </div>
        <button type="button" className="icon-button small pane-dock-toggle" aria-label={PANE_DOCK_TOGGLE} aria-expanded={!collapsed} aria-controls={PANE_BODY_ID} onClick={toggle}>
          <span className="pane-chevron" aria-hidden="true" />
        </button>
      </div>
      <div id={PANE_BODY_ID} className="pane-body" hidden={collapsed}>
        {views.map((view) => <PaneSurface key={view.key} store={store} view={view} label={paneLabel(view, projectOnScreen, projects)} shown={!collapsed && view.key === active} />)}
      </div>
    </section>
  );
}

function PaneTab({ store, view, label, active, choose }: { store: PaneStore; view: PaneView; label: string; active: boolean; choose: (key: string) => void }) {
  const classes = `pane-tab${active ? ' active' : ''}${view.state === 'ended' ? ' ended' : ''}`;
  return (
    <div className={classes}>
      <button type="button" className="pane-tab-name" aria-pressed={active} title={paneTooltip(view)} onClick={() => choose(view.key)}>{label}</button>
      <button type="button" className="pane-tab-close" aria-label={closePaneName(label)} title={closePaneName(label)} onClick={() => store.close(view.key)}>×</button>
    </div>
  );
}

/**
 * One pane's screen. On mount it hands its container to the store, which shows the terminal there
 * and, the first time, opens the pane. While shown it fits the terminal to the dock, again on every
 * window resize. An ended pane says why above the screen it keeps.
 */
function PaneSurface({ store, view, label, shown }: { store: PaneStore; view: PaneView; label: string; shown: boolean }) {
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (container.current !== null) store.showAndConnect(view.key, container.current);
  }, [store, view.key]);
  useEffect(() => {
    if (!shown) return undefined;
    const refit = (): void => store.refit(view.key);
    refit();
    window.addEventListener('resize', refit);
    return () => window.removeEventListener('resize', refit);
  }, [store, view.key, shown, view.ended]);
  return (
    <div className="pane-surface" role="region" aria-label={label} hidden={!shown}>
      {view.ended !== null && <p className="pane-ended" role="status">{view.ended}</p>}
      <div className="pane-screen" ref={container} />
    </div>
  );
}

function usePaneViews(store: PaneStore): readonly PaneView[] {
  const subscribe = useCallback((listener: () => void) => store.subscribe(listener), [store]);
  const read = useCallback(() => store.panes(), [store]);
  return useSyncExternalStore(subscribe, read);
}

type DockState = { active: string | null; collapsed: boolean; choose: (key: string) => void; toggle: () => void };

/** Which pane is in front and whether the dock is folded; a pane that opens comes to the front of an open dock. */
function useDockState(views: readonly PaneView[]): DockState {
  const [known, setKnown] = useState(views);
  const [chosen, setChosen] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState(false);
  if (known !== views) {
    setKnown(views);
    const opened = views.filter((view) => !known.some((each) => each.key === view.key)).at(-1);
    if (opened !== undefined) {
      setChosen(opened.key);
      setCollapsed(false);
    }
  }
  const active = views.some((view) => view.key === chosen) ? chosen : views.at(-1)?.key ?? null;
  const choose = (key: string): void => {
    setChosen(key);
    setCollapsed(false);
  };
  return { active, collapsed, choose, toggle: () => setCollapsed((folded) => !folded) };
}

/** `<run> · <folder name>`, and the project's name when it is not the one on screen. */
function paneLabel(view: PaneView, projectOnScreen: string | null, projects: readonly ProjectSummary[]): string {
  const label = `${view.run} · ${folderName(view.folder)}`;
  if (view.projectId === projectOnScreen) return label;
  const project = projects.find((each) => each.id === view.projectId);
  return `${label} (${project?.name ?? view.projectId})`;
}

function folderName(folder: string): string {
  return folder.split('/').filter((part) => part !== '').at(-1) ?? folder;
}

/** The command the daemon started, once it has; the folder until then. */
function paneTooltip(view: PaneView): string {
  return view.command.length > 0 ? view.command.join(' ') : view.folder;
}
