import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { ActionsDrawer } from '../src/ActionsDrawer.tsx';
import { actionStateLabel } from '../src/actions.ts';
import { actionRecordTone } from '../src/status.ts';
import { ActionButton } from '../src/ui.tsx';
import { useActions } from '../src/useActions.ts';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, HTTP_OK } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';
const NEXT = { job: 'next' };
const close = (): void => {};

test('JobHandedToLaunchd_SaysStarted', () => {
  expect(actionStateLabel(actionRecord('a1', 'done', NEXT)), 'because a job.run that returned has only started the job').toBe('started');
});

test('ActionThatFinishedItsWork_SaysDone', () => {
  expect(actionStateLabel({ ...actionRecord('a1', 'done', NEXT), outcome: 'finished' }), 'because the work is over').toBe('done');
});

test('StartedAction_ReadsAsLiveWork', () => {
  expect(actionRecordTone(actionRecord('a1', 'done', NEXT)), 'because the job it started is still going').toBe('running');
});

test('RunPressedAndJobStarted_ButtonSaysStarted', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [] } }));
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: HTTP_ACCEPTED, body: { action: actionRecord('a1', 'done', NEXT) } }));
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><ActionButton kind="job.run" args={NEXT} label="Run" primary /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run' })); });
  expect(screen.queryByText('started'), 'because "done" would claim the job finished when it only began').not.toBeNull();
});

function Drawer() {
  return <ActionsDrawer actions={useActions('project')} close={close} />;
}

test('DrawerListingAStartedJob_SaysStarted', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [actionRecord('a1', 'done', NEXT)] } }));
  const Wrapper = daemon.wrapper();
  render(<Wrapper><Drawer /></Wrapper>);
  await act(async () => { await Promise.resolve(); });
  expect(screen.getByRole('button', { name: /job\.run/ }).textContent, 'because the drawer uses the same words as the button').toMatch(/^started/);
});
