import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { SettingsView } from '../../daemon/src/snapshot.ts';
import { commandWords, Settings, SETTINGS_PATH } from '../src/screens/Settings.tsx';
import { FakeDaemon, HTTP_OK } from './fakeDaemon.tsx';

afterEach(cleanup);

const HTTP_BAD_REQUEST = 400;

const VIEW: SettingsView = {
  configFile: '/home/o/.config/brain-console/config.json', readFromLegacyFile: null, stateDir: '/home/o/.local/state/brain-console', launchd: false,
  projects: { roots: ['/work/projects/foosbrawl'], from: 'file', editable: true, note: null },
  terminal: { value: null, from: 'default', installed: ['ghostty'] },
  port: { value: 7474, from: 'default', saved: null, note: 'The daemon listens on 7474; a new port takes a restart of the daemon.' },
};

async function renderSettings(view: SettingsView, onPut: (body: unknown) => { status: number; body: unknown } = () => ({ status: HTTP_OK, body: view })) {
  const daemon = new FakeDaemon();
  const puts: unknown[] = [];
  daemon.answer('GET', SETTINGS_PATH, () => ({ status: HTTP_OK, body: view }));
  daemon.answer('PUT', SETTINGS_PATH, (body) => { puts.push(body); return onPut(body); });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Settings /></Wrapper>);
  await act(async () => {});
  return puts;
}

test('Settings_ListsTheProjectsAndTheFiles', async () => {
  await renderSettings(VIEW);
  expect(screen.getByRole('list', { name: 'Watched projects' }).textContent, 'because the screen shows what the daemon watches').toMatch(/foosbrawl/);
  expect(screen.getAllByText(VIEW.configFile).length, 'because the owner may want to edit the file by hand').toBeGreaterThan(0);
  expect(screen.queryByText(VIEW.stateDir), 'because the state folder holds the audit log and the token').not.toBeNull();
});

test('AddProject_PutsTheWholeListWithTheNewRoot', async () => {
  const puts = await renderSettings(VIEW);
  fireEvent.change(screen.getByLabelText('Project root'), { target: { value: '/work/brain' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add' })); });
  expect(puts, 'because the daemon gets the new list and starts watching the root at once').toEqual([{ projects: [{ root: '/work/projects/foosbrawl' }, { root: '/work/brain' }] }]);
});

test('RemoveProject_PutsTheListWithoutIt', async () => {
  const puts = await renderSettings({ ...VIEW, projects: { ...VIEW.projects, roots: ['/a', '/b'] } });
  await act(async () => { fireEvent.click(screen.getAllByRole('button', { name: 'Remove' })[0]!); });
  expect(puts, 'because a removed root stops being watched').toEqual([{ projects: [{ root: '/b' }] }]);
});

test('RefusedSave_SaysWhy', async () => {
  await renderSettings(VIEW, () => ({ status: HTTP_BAD_REQUEST, body: { error: '/nowhere has no .flow/config.yaml; run flow:init there first' } }));
  fireEvent.change(screen.getByLabelText('Project root'), { target: { value: '/nowhere' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add' })); });
  expect(screen.getByRole('alert').textContent, 'because a refused root must say what it lacks').toMatch(/no \.flow\/config\.yaml/);
});

test('ProjectsFromAFlag_NoAddOrRemoveAndTheNoteSaysWhy', async () => {
  await renderSettings({ ...VIEW, projects: { roots: ['/work/projects/foosbrawl'], from: 'flag', editable: false, note: 'Set by --project when the daemon started; start it without the flag to edit them here.' } });
  expect([screen.queryByLabelText('Project root'), screen.queryByRole('button', { name: 'Remove' })], 'because a flag would bring the list back on the next start').toEqual([null, null]);
  expect(screen.queryByText(/Set by --project/), 'because the owner hears why the list is locked').not.toBeNull();
});

test('PickATerminal_SavedAtOnce', async () => {
  const puts = await renderSettings(VIEW);
  await act(async () => { fireEvent.click(screen.getByRole('radio', { name: /^iTerm/ })); });
  expect(puts, 'because a named terminal needs nothing more').toEqual([{ terminal: 'iterm' }]);
});

test('NoTerminalSet_SaysWhichOneOpens', async () => {
  await renderSettings(VIEW);
  expect(screen.getByRole('radio', { name: /first installed/ }).closest('label')?.textContent, 'because the default picks the first installed app and the owner should know which').toMatch(/\(Ghostty\)/);
});

test('CustomCommand_SavedAsItsWords', async () => {
  const puts = await renderSettings(VIEW);
  fireEvent.click(screen.getByRole('radio', { name: 'Custom command' }));
  fireEvent.change(screen.getByRole('textbox', { name: 'Command words' }), { target: { value: 'open -a Warp  {path}' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Save' })); });
  expect(puts, 'because the daemon keeps a command as an argv array and runs it without a shell').toEqual([{ terminal: { command: ['open', '-a', 'Warp', '{path}'] } }]);
});

test('CommandWords_EmptyTextHasNone', () => {
  expect(commandWords('   '), 'because an empty command is refused before it is sent').toEqual([]);
});

test('Port_ReadOnlyWithTheRestartNote', async () => {
  await renderSettings(VIEW);
  expect([screen.queryByRole('spinbutton'), screen.queryByText(/takes a restart/)], 'because the port cannot change while the daemon listens on it').toEqual([null, expect.anything()]);
});

test('UnderLaunchd_SaysSo', async () => {
  await renderSettings({ ...VIEW, launchd: true });
  expect(screen.queryByText(/launchd: it starts on login/), 'because the owner should know whether the daemon comes back by itself').not.toBeNull();
});
