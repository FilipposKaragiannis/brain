import type { ReactNode } from 'react';
import type { ProjectInfo } from '../../daemon/src/snapshot.ts';
import { ExternalLink } from './links.tsx';
import { SETTINGS_HASH } from './route.ts';
import { WORDS } from './words.ts';

/** What the tracker value says for each adapter; another adapter shows its own name. */
const TRACKER_WORDS: Record<string, string> = { github: 'GitHub issues', local: 'local' };

/** How the plugin was found, for the Flow plugin field's tooltip. */
export function pluginTitle(project: ProjectInfo): string {
  if (project.pluginSource === null || project.pluginRoot === null) return 'No flow plugin found for this project';
  if (project.pluginSource === 'FLOW_PLUGIN') return `Set by FLOW_PLUGIN when the daemon started: ${project.pluginRoot}`;
  return `The installed plugin, as .flow/plugin.sh finds it: ${project.pluginRoot}`;
}

/**
 * Which project this is, as a row of labelled fields: a small label over each value, so every
 * word says what it is. The fields wrap at phone width; Settings stays at the far right.
 */
export function ProjectHeader({ project }: { project: ProjectInfo }) {
  const tracker = TRACKER_WORDS[project.adapter] ?? project.adapter;
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
        <Field label="Flow plugin" title={pluginTitle(project)}>{project.pluginVersion ?? 'not found'}</Field>
        <Field label="Jobs run on" title="jobs.host: the CLI the scheduled jobs run">{project.jobsHost}</Field>
      </dl>
      <a className="project-settings" href={SETTINGS_HASH} title={WORDS.projects}>Settings</a>
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
