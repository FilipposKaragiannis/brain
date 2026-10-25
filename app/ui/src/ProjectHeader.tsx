import type { ProjectInfo } from '../../daemon/src/snapshot.ts';
import { ExternalLink } from './links.tsx';
import { WORDS } from './words.ts';

/** One line on which project this is: its repository and tracker, adapter, base branch, flow version and jobs host. */
export function ProjectHeader({ project }: { project: ProjectInfo }) {
  return (
    <section className="project-bar" aria-label="Project details">
      <span className="project-name" title={project.root}>{project.name}</span>
      {project.repoUrl !== null && <ExternalLink url={project.repoUrl} className="">{project.repo ?? 'repository'}</ExternalLink>}
      {project.trackerUrl !== null && <ExternalLink url={project.trackerUrl} className="">tracker</ExternalLink>}
      <span title="adapters.default: where the items live">{project.adapter}</span>
      <span title="The branch work merges into">base <span className="mono">{project.base}</span></span>
      <span title="The flow plugin this project resolves">flow {project.pluginVersion ?? '?'}</span>
      <span title="jobs.host: the CLI the scheduled jobs run">jobs on {project.jobsHost}</span>
      <span className="project-note">{WORDS.projects}</span>
    </section>
  );
}
