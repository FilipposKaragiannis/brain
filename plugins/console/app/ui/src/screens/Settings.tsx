import { useCallback, useEffect, useState } from 'react';
import type { SettingOrigin, SettingsView, TerminalName, TerminalSetting } from '../../../daemon/src/snapshot.ts';
import { unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { Empty, Module } from '../ui.tsx';
import { FlowSettingsList } from './FlowSettings.tsx';
import { HTTP_OK } from '../useProject.ts';

export const SETTINGS_PATH = '/api/settings';

const TERMINAL_LABELS: Record<TerminalName, string> = { iterm: 'iTerm', terminal: 'Terminal', ghostty: 'Ghostty' };
const TERMINAL_ORDER: TerminalName[] = ['iterm', 'terminal', 'ghostty'];
const ORIGIN_WORDS: Record<SettingOrigin, string> = { flag: 'set by a start flag', environment: 'set by the environment', file: 'from the config file', default: 'the default' };

type Read = { kind: 'loading' } | { kind: 'read'; view: SettingsView } | { kind: 'unreachable'; message: string };
/** The terminal radio: a named app, the first one installed, or the owner's own command. */
type Choice = TerminalName | 'auto' | 'custom';

function choiceOf(value: TerminalSetting | null): Choice {
  if (value === null) return 'auto';
  return typeof value === 'string' ? value : 'custom';
}

/**
 * A custom command as typed: a JSON array of strings, so a word may hold a space (an app path
 * such as "/Applications/My Term.app"). Returns the words, or why the text is not one.
 */
export function parseCommand(text: string): { ok: true; words: string[] } | { ok: false; error: string } {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return { ok: false, error: 'write the command as a JSON array, such as ["open", "-a", "Warp", "{path}"]' }; }
  if (!Array.isArray(parsed) || parsed.length === 0 || !parsed.every((word) => typeof word === 'string' && word !== '')) {
    return { ok: false, error: 'the command must be a JSON array of non-empty strings' };
  }
  return { ok: true, words: parsed as string[] };
}

/**
 * The daemon's settings: the projects it watches (added and removed live), the terminal Open in
 * Terminal uses, the port (read only, a change takes a restart) and where its files are. Every
 * change is one PUT; the daemon checks it whole and says why when it refuses.
 */
export function Settings() {
  const { api } = useServices();
  const [read, setRead] = useState<Read>({ kind: 'loading' });
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void api.request(SETTINGS_PATH, 'GET', null).then((response) => {
      if (cancelled) return;
      setRead(response.status === HTTP_OK && response.body !== null ? { kind: 'read', view: response.body as SettingsView } : { kind: 'unreachable', message: unreachableMessage(response.status) });
    });
    return () => { cancelled = true; };
  }, [api]);

  const save = useCallback(async (change: Record<string, unknown>): Promise<boolean> => {
    setSaving(true);
    const response = await api.request(SETTINGS_PATH, 'PUT', change);
    setSaving(false);
    if (response.status === HTTP_OK && response.body !== null) { setRead({ kind: 'read', view: response.body as SettingsView }); setError(null); return true; }
    const message = (response.body as { error?: unknown } | null)?.error;
    setError(typeof message === 'string' ? message : unreachableMessage(response.status));
    return false;
  }, [api]);

  if (read.kind === 'loading') return <Empty>Reading the settings…</Empty>;
  if (read.kind === 'unreachable') return <Empty>{read.message}.</Empty>;
  const { view } = read;
  const footer = <span className="muted">Saved in <span className="mono">{view.configFile}</span></span>;
  return (
    <div className="screen settings">
      {error !== null && <p className="banner tone-failing" role="alert">Not saved: {error}</p>}
      <Module className="settings-projects" title="Projects" aside={<span className="muted">{ORIGIN_WORDS[view.projects.from]}</span>} footer={footer}>
        <Projects view={view} saving={saving} save={save} />
      </Module>
      <Module className="settings-terminal" title="Terminal" aside={<span className="muted">{ORIGIN_WORDS[view.terminal.from]}</span>} footer={footer}>
        <Terminal view={view} saving={saving} save={save} />
      </Module>
      <Module className="settings-daemon" title="Daemon" aside={null} footer={footer}>
        <dl className="settings-facts">
          <dt>Port</dt><dd><span className="mono">{view.port.value}</span> <span className="muted">({ORIGIN_WORDS[view.port.from]})</span>{view.port.saved !== null && view.port.saved !== view.port.value && <> · <span className="mono">{view.port.saved}</span> saved for the next start</>}<p className="module-help">{view.port.note}</p></dd>
          <dt>Config file</dt><dd className="mono">{view.configFile}</dd>
          {view.readFromLegacyFile !== null && <><dt>Projects read from</dt><dd><span className="mono">{view.readFromLegacyFile}</span> <span className="muted">(config.json is absent; the first save writes it)</span></dd></>}
          <dt>State folder</dt><dd className="mono" title="The audit log, the action output and the token">{view.stateDir}</dd>
          <dt>Runs under</dt><dd>{view.launchd ? 'launchd: it starts on login and comes back after a crash.' : <>a terminal: it stops when that terminal does. <span className="mono">npm run daemon:install</span> in <span className="mono">app</span> runs it on login.</>}</dd>
        </dl>
      </Module>
      <FlowSettingsList />
    </div>
  );
}

type Part = { view: SettingsView; saving: boolean; save: (change: Record<string, unknown>) => Promise<boolean> };

function Projects({ view, saving, save }: Part) {
  const [root, setRoot] = useState('');
  const { roots, editable, note } = view.projects;
  const put = (next: string[]): Promise<boolean> => save({ projects: next.map((entry) => ({ root: entry })) });
  return (
    <>
      {note !== null && <p className="module-help">{note}</p>}
      <ul className="settings-list" aria-label="Watched projects">
        {roots.map((entry) => (
          <li key={entry}>
            <span className="mono">{entry}</span>
            {editable && <button type="button" className="button" disabled={saving || roots.length === 1} title={roots.length === 1 ? 'The daemon watches one project at least' : undefined} onClick={() => { void put(roots.filter((other) => other !== entry)); }}>Remove</button>}
          </li>
        ))}
      </ul>
      {editable && (
        <form className="settings-add" onSubmit={(event) => { event.preventDefault(); if (root.trim() !== '') void put([...roots, root.trim()]).then((saved) => { if (saved) setRoot(''); }); }}>
          <input aria-label="Project root" className="input mono" placeholder="/path/to/project (holds .flow/config.yaml)" value={root} onChange={(event) => setRoot(event.target.value)} />
          <button type="submit" className="button primary" disabled={saving || root.trim() === ''}>Add</button>
        </form>
      )}
    </>
  );
}

function Terminal({ view, saving, save }: Part) {
  const current = view.terminal.value;
  const [choice, setChoice] = useState<Choice>(choiceOf(current));
  const [command, setCommand] = useState(typeof current === 'object' && current !== null ? JSON.stringify(current.command) : '');
  const parsed = parseCommand(command);
  const first = view.terminal.installed[0];
  const pick = (next: Choice): void => {
    setChoice(next);
    if (next === 'auto') void save({ terminal: null });
    else if (next !== 'custom') void save({ terminal: next });
  };
  return (
    <fieldset className="settings-terminal-choice" disabled={saving}>
      <legend className="module-help">Open in Terminal opens a folder (or a job's log) in this app.</legend>
      <label><input type="radio" name="terminal" checked={choice === 'auto'} onChange={() => pick('auto')} /> The first installed of iTerm, Ghostty, Terminal {first === undefined ? '(none found)' : `(${TERMINAL_LABELS[first]})`}</label>
      {TERMINAL_ORDER.map((name) => (
        <label key={name}><input type="radio" name="terminal" checked={choice === name} onChange={() => pick(name)} /> {TERMINAL_LABELS[name]}{!view.terminal.installed.includes(name) && <span className="muted"> (not found)</span>}</label>
      ))}
      <label><input type="radio" name="terminal" checked={choice === 'custom'} onChange={() => pick('custom')} /> Custom command</label>
      {choice === 'custom' && (
        <form className="settings-add" onSubmit={(event) => { event.preventDefault(); if (parsed.ok) void save({ terminal: { command: parsed.words } }); }}>
          <input aria-label="Command as a JSON array" className="input mono" placeholder='["open", "-a", "Warp", "{path}"]' value={command} onChange={(event) => setCommand(event.target.value)} aria-invalid={command !== '' && !parsed.ok} />
          <button type="submit" className="button primary" disabled={!parsed.ok}>Save</button>
          {command !== '' && !parsed.ok && <p className="module-help tone-failing" role="status">{parsed.error}</p>}
          <p className="module-help">A JSON array of words, run without a shell. <span className="mono">{'{path}'}</span> is the folder as it is, for a word of its own; inside an <span className="mono">sh -c</span> string use <span className="mono">{'{qpath}'}</span>, the folder quoted for sh, and <span className="mono">{'{cmd}'}</span>, the command to run there (a job's log), quoted already. With neither path the folder goes last.</p>
        </form>
      )}
    </fieldset>
  );
}
