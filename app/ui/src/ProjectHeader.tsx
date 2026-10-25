import type { ProjectInfo } from '../../daemon/src/snapshot.ts';
import { WORDS } from './words.ts';

/** One line on which project this is: its repository and tracker, adapter, base branch, flow version and jobs host. */
export function ProjectHeader({ project }: { project: ProjectInfo }) {
  return (
    <section className="project-bar" aria-label="Project details">
      <span className="project-name" title={`${project.root}. ${WORDS.projects}`}>{project.name}</span>
      {project.repoUrl !== null && <a href={project.repoUrl} target="_blank" rel="noreferrer">{project.repo ?? 'repository'}</a>}
      {project.trackerUrl !== null && <a href={project.trackerUrl} target="_blank" rel="noreferrer">tracker</a>}
      <span title="adapters.default: where the items live">{project.adapter}</span>
      <span title="The branch work merges into">base <span className="mono">{project.base}</span></span>
      <span title="The flow plugin this project resolves">flow {project.pluginVersion ?? '?'}</span>
      <span title="jobs.host: the CLI the scheduled jobs run">jobs on {project.jobsHost}</span>
      <span className="project-note">{WORDS.projects}</span>
    </section>
  );
}
