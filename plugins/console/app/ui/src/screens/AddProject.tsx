import { useState } from 'react';
import type { ProjectCheck, ProjectCheckName } from '../../../daemon/src/snapshot.ts';
import { unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { routeHash } from '../route.ts';
import { HTTP_OK } from '../useProject.ts';

export const CHECK_PROJECT_PATH = '/api/settings/check-project';

const STEPS = ['Folder', 'Check', 'Confirm', 'Done'] as const;
const CHECK_LABELS: Record<ProjectCheckName, string> = { path: 'Absolute path', exists: 'Folder exists', git: 'Git checkout', flow: '.flow/config.yaml', watched: 'Not watched yet', name: 'Name is free' };

type Step =
  | { at: 'Folder' }
  | { at: 'Check'; checking: boolean; check: ProjectCheck | null; error: string | null }
  | { at: 'Confirm'; check: ProjectCheck }
  | { at: 'Done'; check: ProjectCheck };

/**
 * Adds a project step by step: the folder; the daemon's check of it (the very checks the PUT
 * makes, each shown, with the flow:init line when the folder has no flow yet and Check again);
 * the name and root to confirm, added with one PUT of the whole list; and a link to its overview.
 */
export function AddProject({ roots, saving, save, close }: { roots: string[]; saving: boolean; save: (change: Record<string, unknown>) => Promise<boolean>; close: () => void }) {
  const { api } = useServices();
  const [folder, setFolder] = useState('');
  const [step, setStep] = useState<Step>({ at: 'Folder' });

  const check = async (): Promise<void> => {
    setStep({ at: 'Check', checking: true, check: step.at === 'Check' ? step.check : null, error: null });
    const response = await api.request(CHECK_PROJECT_PATH, 'POST', { root: folder.trim() });
    if (response.status === HTTP_OK && response.body !== null) { setStep({ at: 'Check', checking: false, check: response.body as ProjectCheck, error: null }); return; }
    const error = (response.body as { error?: unknown } | null)?.error;
    setStep({ at: 'Check', checking: false, check: null, error: typeof error === 'string' ? error : unreachableMessage(response.status) });
  };
  const add = async (found: ProjectCheck): Promise<void> => {
    if (await save({ projects: [...roots, found.root].map((root) => ({ root })) })) setStep({ at: 'Done', check: found });
  };
  const again = (): void => { setFolder(''); setStep({ at: 'Folder' }); };

  return (
    <section className="add-project" aria-label="Add a project">
      <ol className="wizard-steps" aria-label="Steps">
        {STEPS.map((name, index) => <li key={name} aria-current={step.at === name ? 'step' : undefined} className={step.at === name ? 'current' : undefined}>{index + 1}. {name}</li>)}
      </ol>
      {step.at === 'Folder' && (
        <form className="settings-add" onSubmit={(event) => { event.preventDefault(); if (folder.trim() !== '') void check(); }}>
          <p className="module-help">The folder of a git checkout that holds .flow/config.yaml. <span className="mono">~/</span> is your home folder.</p>
          <input aria-label="Project folder" className="input mono" placeholder="/path/to/project" value={folder} onChange={(event) => setFolder(event.target.value)} autoFocus />
          <button type="button" className="button" onClick={close}>Cancel</button>
          <button type="submit" className="button primary" disabled={folder.trim() === ''}>Check the folder</button>
        </form>
      )}
      {step.at === 'Check' && (
        <div className="wizard-body">
          {step.checking && <p className="module-help" role="status">Checking {folder.trim()}…</p>}
          {step.error !== null && <p className="module-help tone-failing" role="status">The check did not run: {step.error}</p>}
          {step.check !== null && <Findings check={step.check} />}
          <div className="wizard-buttons">
            <button type="button" className="button" onClick={() => setStep({ at: 'Folder' })}>Back</button>
            <button type="button" className="button" disabled={step.checking} onClick={() => { void check(); }}>Check again</button>
            <button type="button" className="button primary" disabled={step.checking || step.check?.ok !== true} onClick={() => { if (step.check !== null) setStep({ at: 'Confirm', check: step.check }); }}>Next</button>
          </div>
        </div>
      )}
      {step.at === 'Confirm' && (
        <div className="wizard-body">
          <dl className="settings-facts">
            <dt>Name</dt><dd className="mono">{step.check.id}</dd>
            <dt>Root</dt><dd className="mono">{step.check.root}</dd>
          </dl>
          <p className="module-help">The console names a project by its folder. Adding it saves the project list to the console's settings file and starts watching it at once.</p>
          <div className="wizard-buttons">
            <button type="button" className="button" disabled={saving} onClick={() => setStep({ at: 'Check', checking: false, check: step.check, error: null })}>Back</button>
            <button type="button" className="button primary" disabled={saving} onClick={() => { void add(step.check); }}>Add {step.check.id}</button>
          </div>
        </div>
      )}
      {step.at === 'Done' && (
        <div className="wizard-body">
          <p className="module-help" role="status">The console watches {step.check.id} now. Its settings show under Plugins, Jobs and Agents.</p>
          <div className="wizard-buttons">
            <a className="button primary" href={routeHash({ projectId: step.check.id, screen: 'overview', detail: null })}>Open the {step.check.id} overview</a>
            <button type="button" className="button" onClick={again}>Add another</button>
            <button type="button" className="button" onClick={close}>Close</button>
          </div>
        </div>
      )}
    </section>
  );
}

/** Each check with its outcome, then what to do about the first one that failed. */
function Findings({ check }: { check: ProjectCheck }) {
  return (
    <>
      <ul className="wizard-checks" aria-label="Checks">
        {check.findings.map((finding) => (
          <li key={finding.check} className={finding.ok ? 'tone-running' : 'tone-failing'}>
            <span className="wizard-mark" aria-hidden="true">{finding.ok ? '✓' : '✗'}</span>
            <strong>{CHECK_LABELS[finding.check]}</strong> <span className="muted">{finding.ok ? '' : 'failed: '}{finding.text}</span>
          </li>
        ))}
      </ul>
      {check.initCommand !== null && (
        <div className="wizard-init">
          <p className="module-help">This folder has no flow yet. Run flow:init there first, in Claude Code, then check again:</p>
          <pre className="wizard-command mono" aria-label="flow:init command">{check.initCommand}</pre>
        </div>
      )}
      {!check.ok && check.findings.every((finding) => finding.ok) && check.error !== null && <p className="module-help tone-failing">The project list would be refused: {check.error}</p>}
      {check.ok && <p className="module-help">Every check passed: {check.root} can be added as {check.id}.</p>}
    </>
  );
}
