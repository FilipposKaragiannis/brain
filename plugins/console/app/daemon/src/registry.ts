import type { ActionRunner } from './actions.ts';
import type { Logger } from './log.ts';
import type { FlowConfigEditor } from './plugins/flow/configEditor.ts';
import type { ProjectDefinition, ProjectMonitor } from './project.ts';
import type { Counts } from './snapshot.ts';

/** One project as the server sees it: its live picture, the thing that runs its actions, and the editor of its .flow/config.yaml. */
export type ServedProject = { monitor: ProjectMonitor; actions: ActionRunner; flowConfig: FlowConfigEditor };

/** A project in `GET /api/projects` and in the `projects` event: its definition and its counts. */
export type ProjectSummary = ProjectDefinition & { counts: Counts | null; takenAt: string | null };

/** Makes the monitor and the runner of one project, not started yet. */
export type ProjectFactory = (project: ProjectDefinition) => ServedProject;

/**
 * The projects the daemon watches. `apply` makes the list match a new one while the daemon runs:
 * a new root gets its monitor started, a removed one is stopped and dropped, and listeners hear
 * the new list.
 */
export class ProjectRegistry {
  private readonly factory: ProjectFactory;
  private readonly log: Logger;
  private readonly served = new Map<string, ServedProject>();
  private readonly listeners = new Set<(projects: ProjectSummary[]) => void>();

  constructor(factory: ProjectFactory, log: Logger) {
    this.factory = factory;
    this.log = log;
  }

  list(): ServedProject[] { return [...this.served.values()]; }

  get(id: string): ServedProject | undefined { return this.served.get(id); }

  summaries(): ProjectSummary[] {
    return this.list().map(({ monitor }) => ({ ...monitor.project, counts: monitor.snapshot?.counts ?? null, takenAt: monitor.snapshot?.takenAt ?? null }));
  }

  onChange(listener: (projects: ProjectSummary[]) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  /**
   * Watches exactly these projects. A project whose root changed under the same id starts over.
   * Listeners hear the list at once; the promise settles when every new monitor has made its
   * first reads.
   */
  async apply(projects: ProjectDefinition[]): Promise<void> {
    const wanted = new Map(projects.map((project) => [project.id, project]));
    let changed = false;
    for (const [id, entry] of [...this.served]) {
      if (wanted.get(id)?.root === entry.monitor.project.root) continue;
      entry.actions.stopAll();
      entry.monitor.stop();
      this.served.delete(id);
      this.log.info('project.removed', { project: id, root: entry.monitor.project.root });
      changed = true;
    }
    const starting: Promise<void>[] = [];
    for (const project of projects) {
      if (this.served.has(project.id)) continue;
      const entry = this.factory(project);
      this.served.set(project.id, entry);
      this.log.info('project.added', { project: project.id, root: project.root });
      starting.push(entry.monitor.start());
      changed = true;
    }
    if (changed) {
      const summaries = this.summaries();
      for (const listener of this.listeners) listener(summaries);
    }
    await Promise.all(starting);
  }

  /** Stops every monitor and every attached action; the daemon is shutting down. */
  stopAll(): void {
    for (const { monitor, actions } of this.served.values()) { actions.stopAll(); monitor.stop(); }
  }
}
