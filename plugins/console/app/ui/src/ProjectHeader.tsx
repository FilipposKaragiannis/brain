import type { ReactNode } from 'react';
import type { ProjectInfo, TrackerInfo } from '../../daemon/src/snapshot.ts';
import { ExternalLink } from './links.tsx';

/** What the tracker value says for each adapter; another adapter shows its own name. */
const TRACKER_WORDS: Record<string, string> = { github: 'GitHub issues', jira: 'Jira', local: 'local' };

/** What follows a tracker the board could not read; its title says why. */
export const NOT_READ = 'not read';

export const JOB_HOSTS_TITLE = 'The hosts the schedules and their workers run on';

/**
 * Which project this is, as a row of labelled fields: a small label over each value, so every
 * word says what it is. The fields wrap at phone width; the top bar holds the Settings button.
 */
export function ProjectHeader({ project }: { project: ProjectInfo }) {
  const hosts = project.jobHosts.length > 0 ? project.jobHosts : [project.jobsHost];
  return (
    <section className="project-bar" aria-label="Project details">
      <dl className="project-fields">
        <Field label="Project" title={project.root}><span className="project-name">{project.name}</span></Field>
        <Field label="Repository" title="github.repo: where the code lives">
          {project.repoUrl !== null ? <ExternalLink url={project.repoUrl} className="">{project.repo ?? 'repository'}</ExternalLink> : <span className="muted">none</span>}
        </Field>
        <Field label={project.trackers.length > 1 ? 'Trackers' : 'Tracker'} title={`trackers: where the flow reads items; new ones go to ${project.adapter}`}>
          {project.trackers.map((tracker, index) => <span key={tracker.name}>{index > 0 && ', '}<Tracker tracker={tracker} /></span>)}
        </Field>
        <Field label="Base branch" title="The branch work merges into"><span className="mono">{project.base}</span></Field>
        <Field label="Jobs run on" title={JOB_HOSTS_TITLE}>{hosts.join(', ')}</Field>
      </dl>
    </section>
  );
}

/** One tracker by name, linked to its items when it has a page, marked when the board could not read it. */
function Tracker({ tracker }: { tracker: TrackerInfo }) {
  const words = TRACKER_WORDS[tracker.name] ?? tracker.name;
  return (
    <>
      {tracker.url !== null ? <ExternalLink url={tracker.url} className="">{words}</ExternalLink> : words}
      {tracker.error !== null && <> <span className="tone-failing tracker-not-read" title={tracker.error}>({NOT_READ})</span></>}
    </>
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
