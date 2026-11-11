import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { PaneControls, quickSessionName, TERMINAL_PANE } from '../src/PaneControls.tsx';
import { PaneDock } from '../src/PaneDock.tsx';
import { FakeDaemon } from './fakeDaemon.tsx';

afterEach(cleanup);

const FOLDER = '/work/foosbrawl-wt/wt-4';

/** The controls for one folder with the dock beside them, as the page has both. */
function clickInControls(name: string): { path: string | null; run: string | null }[] {
  const daemon = new FakeDaemon();
  const Wrapper = daemon.wrapper();
  render(<Wrapper><PaneControls projectId="foosbrawl" folder={FOLDER} /><PaneDock projectOnScreen="foosbrawl" projects={[]} /></Wrapper>);
  act(() => { fireEvent.click(screen.getByRole('button', { name })); });
  return daemon.sockets.map((socket) => ({ path: socket.queryParameter('path'), run: socket.queryParameter('run') }));
}

test('TerminalPane_OpensAShellInTheFolder', () => {
  expect(clickInControls(TERMINAL_PANE), 'because one click opens one shell in the folder the button sits beside').toEqual([{ path: FOLDER, run: 'shell' }]);
});

test('QuickSessionClaude_StartsClaudeInTheFolder', () => {
  expect(clickInControls(quickSessionName('claude')), 'because a quick session runs the agent itself in that folder, not a shell').toEqual([{ path: FOLDER, run: 'claude' }]);
});
