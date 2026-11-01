import type { ReactNode } from 'react';
import type { ProjectInfo } from '../../daemon/src/snapshot.ts';
import { ExternalLink } from './links.tsx';

/** What the tracker value says for each adapter; another adapter shows its own name. */
const TRACKER_WORDS: Record<string, string> = { github: 'GitHub issues', local: 'local' };

export const JOB_HOSTS_TITLE = 'The hosts the schedules and their workers run on';

/**
 * Which project this is, as a row of labelled fields: a small label over each value, so every
 * word says what it is. The fields wrap at phone width; the top bar holds the Settings button.
 */
export function ProjectHeader({ project }: { project: ProjectInfo }) {
  const tracker = TRACKER_WORDS[project.adapter] ?? project.adapter;
  const hosts = project.jobHosts.length > 0 ? project.jobHosts : [project.jobsHost];
  return (
    <section className="project-bar" aria-label="Project details">
      <dl className="project-fields">
        <Field label="Project" title={project.root}><span className="project-name">{project.name}</span></Field>
        <Field label="Repository" title="github.repo: where the code lives">
          {project.repoUrl !== null ? <ExternalLink url={project.repoUrl} className="">{project.repo ?? 'repository'}</ExternalLink> : <span className="muted">none</span>}
        </Field>
        <Field label="Tracker" title="adapters.default: where the items live">
          {project.trackerUrl !== null ? <ExternalLink url={project.trackerUrl} className="">{tracker}</ExternalLink> : tracker}
        </Field>
        <Field label="Base branch" title="The branch work merges into"><span className="mono">{project.base}</span></Field>
        <Field label="Jobs run on" title={JOB_HOSTS_TITLE}>{hosts.join(', ')}</Field>
      </dl>
    </section>
  );
}

function Field({ label, title, children }: { label: string; title: string; children: ReactNode }) {
  return (
    <div className="project-field" title={title}>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}
