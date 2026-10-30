import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { EndedAgent, Gate, Job, Snapshot } from '../../daemon/src/snapshot.ts';
import { Gates } from '../src/screens/Gates.tsx';
import type { ActionRecord } from '../src/actions.ts';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, HTTP_CONFLICT, snapshotAt, TAKEN_AT, waitingGate } from './fakeDaemon.tsx';

afterEach(cleanup);

const PULL = { number: 560, url: 'https://github.com/owner/project/pull/560', state: 'checks-failing' as const, unresolvedThreads: 2 };

const ACTIONS_PATH = '/api/projects/project/actions';

function renderGate(gate: Gate, daemon = new FakeDaemon(), more: Partial<Snapshot> = {}): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Gates snapshot={{ ...snapshotAt(TAKEN_AT, 1), ...more, gates: [gate] }} selected={gate.item} /></Wrapper>);
}

const ASKING: Gate = {
  ...waitingGate('gh#504', 'ambiguity'),
  message: 'Two forks need you.\n1. What counts as a failed action? Recommended: the ball misses the target.\n2. Anything else?',
  questions: [{ number: 1, text: 'What counts as a failed action?', recommended: 'the ball misses the target.' }, { number: 2, text: 'Anything else?', recommended: null }],
};

/**
 * A daemon that takes every action, records what was posted, and answers with a running record of
 * the same kind. `refuseRuns` turns run.start down the way a held queue lock does.
 */
function recordingDaemon(refuseRuns = false): { daemon: FakeDaemon; posted: { kind: string; args: Record<string, string> }[] } {
  const daemon = new FakeDaemon();
  const posted: { kind: string; args: Record<string, string> }[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => {
    const action = body as { kind: ActionRecord['kind']; args: Record<string, string> };
    posted.push(action);
    if (refuseRuns && action.kind === 'run.start') return { status: HTTP_CONFLICT, body: { error: 'job:next is held by action b7 (run.start)' } };
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord(`a${posted.length}`, 'running', action.args), kind: action.kind } } };
  });
  return { daemon, posted };
}

/** The gate.clear record the stream sends once the clear ends. */
async function clearEnds(daemon: FakeDaemon, state: ActionRecord['state']): Promise<void> {
  await act(async () => { daemon.latestStream().send('action', { ...actionRecord('a1', state, {}), kind: 'gate.clear', outcome: 'finished' }); });
}

const PLAN_GATE: Gate = { ...waitingGate('gh#514', 'plan-approval'), message: '**Approve the plan, approve it with notes, or send it back.**\n\n- Three slices.', questions: [], plan: { file: 'plan.md', text: '## Phase 1\nWrite the drill.' } };

const NEXT_JOB: Job = { name: 'next', state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };

async function press(name: string): Promise<void> {
  await act(async () => { fireEvent.click(screen.getByRole('button', { name })); });
}

test('MergeGateWithAPull_LinksThePullRequest', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.getByRole('link', { name: 'PR #560' }).getAttribute('href'), 'because the merge happens on the PR').toBe(PULL.url);
});

test('PullWithUnresolvedThreads_CountsThem', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.queryByText('2 unresolved review threads'), 'because an open thread is why a merge gate still waits').not.toBeNull();
});

test('PullWithUnresolvedThreads_SaysTheCommentsJobHandlesThem', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.queryByText(/The comments job addresses threads/), 'because the owner should know who answers the thread').not.toBeNull();
});

test('PullWithNoThreads_NoCommentsLine', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: { ...PULL, unresolvedThreads: 0 } });
  expect(screen.queryByText(/The comments job addresses threads/), 'because nothing is open for the job to address').toBeNull();
});

test('MessageWithABoldFirstLine_ThatLineAsksOverTheButtons', () => {
  renderGate(PLAN_GATE);
  expect(screen.getByRole('group', { name: 'Approve the plan, approve it with notes, or send it back.' }), 'because the decision asked for should sit with the buttons that make it').not.toBeNull();
});

test('MessageWithNoBoldFirstLine_AskSaysWhatTheKindAsks', () => {
  renderGate({ ...waitingGate('gh#515', 'decomposition'), message: 'Four tasks.', questions: [] });
  expect(screen.getByRole('group', { name: 'Approve the split, or send it back.' }), 'because a gate raised before the bold ask still needs one').not.toBeNull();
});

test('EscalationWithNoNumberedQuestion_OneAnswerBoxNoQuestionOne', () => {
  renderGate({ ...waitingGate('gh#577', 'escalation'), message: 'Three attempts failed.', questions: [{ number: 1, text: 'Three attempts failed.', recommended: null }] });
  expect(screen.queryByText('Question 1'), 'because the message asks nothing numbered, so there is no question 1').toBeNull();
  expect(screen.getByLabelText('Your answer'), 'because the owner still needs one place to answer').not.toBeNull();
});

test('EscalationWithNoAnswerTyped_SendDisabled', () => {
  renderGate({ ...waitingGate('gh#577', 'escalation'), message: 'Three attempts failed.', questions: [] });
  expect((screen.getByRole('button', { name: 'Send answer' }) as HTMLButtonElement).disabled, 'because an empty answer tells the agent nothing').toBe(true);
});

test('TextBeforeTheQuestions_ShownAsTheBrief', () => {
  renderGate(ASKING);
  expect(screen.queryByText('Two forks need you.'), 'because the lines before question 1 say why the agent stopped').not.toBeNull();
});

test('QuestionWithARecommendation_RecommendedIsPicked', () => {
  renderGate(ASKING);
  expect((screen.getAllByRole('radio')[0] as HTMLInputElement).checked, 'because accepting the agent\'s recommendation should take no typing').toBe(true);
});

test('SomethingElsePicked_OpensATextBox', () => {
  renderGate(ASKING);
  fireEvent.click(screen.getByRole('radio', { name: 'Something else' }));
  expect(screen.getByLabelText('Your answer to question 1'), 'because the owner writes their own answer only when they turn the recommendation down').not.toBeNull();
});

test('MarkdownInTheMessage_Rendered', () => {
  renderGate({ ...waitingGate('gh#577', 'escalation'), message: 'Check **every** preset.', questions: [] });
  expect(screen.getByText('every').tagName, 'because agents write markdown and the card should read like it').toBe('STRONG');
});

test('PlanGateWithAPlan_ShowsThePlanOpen', () => {
  renderGate(PLAN_GATE);
  expect((screen.getByText('Plan').closest('details') as HTMLDetailsElement).open, 'because the owner is asked to judge the plan').toBe(true);
});

test('OtherGateWithAPlan_PlanFolded', () => {
  renderGate({ ...waitingGate('gh#514', 'feel-test'), plan: { file: 'plan.md', text: 'Write the drill.' } });
  expect((screen.getByText('Plan').closest('details') as HTMLDetailsElement).open, 'because a feel test is about the build, not the plan').toBe(false);
});

test('PlanGateWithNoPlan_SpecOpen', () => {
  renderGate({ ...waitingGate('gh#525', 'plan-approval'), body: '## Goal\nHold to charge.' });
  expect((screen.getByText('Spec').closest('details') as HTMLDetailsElement).open, 'because the spec in the issue is all there is to judge').toBe(true);
});

test('PlanGate_Approve_PostsApproved', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  await press('Approve');
  expect(posted, 'because approving as is takes one press').toEqual([{ kind: 'gate.clear', args: { item: 'gh#514', message: 'Approved.' } }]);
});

test('PlanGate_ApproveWithNotesAndNoNotes_CannotSend', async () => {
  renderGate(PLAN_GATE);
  await press('Approve with notes…');
  expect((screen.getByRole('button', { name: 'Approve with notes' }) as HTMLButtonElement).disabled, 'because notes are the point of approving with notes').toBe(true);
});

test('PlanGate_ApproveWithNotes_PostsTheNotes', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  await press('Approve with notes…');
  fireEvent.change(screen.getByLabelText('Your notes for the agent'), { target: { value: 'Keep slice 3 small.' } });
  await press('Approve with notes');
  expect(posted, 'because the notes travel with the approval').toEqual([{ kind: 'gate.clear', args: { item: 'gh#514', message: 'Approved, with these notes:\n\nKeep slice 3 small.' } }]);
});

test('PlanGate_SendBack_PostsBackWithTheNotes', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  await press('Send back…');
  fireEvent.change(screen.getByLabelText('What should change?'), { target: { value: 'Add a rollback phase.' } });
  await press('Send back');
  expect(posted, 'because sending back runs the plan step again, with the notes in its brief').toEqual([{ kind: 'gate.clear', args: { item: 'gh#514', message: 'Add a rollback phase.', back: 'true' } }]);
});

test('PlanGate_CancelNotes_TheThreeChoicesAgain', async () => {
  renderGate(PLAN_GATE);
  await press('Send back…');
  await press('Cancel');
  expect(screen.queryByRole('button', { name: 'Approve' }), 'because cancel takes the owner back to the choice').not.toBeNull();
});

test('InterviewGate_SaysConfirm', () => {
  renderGate({ ...waitingGate('gh#600', 'interview'), questions: [] });
  expect(screen.queryByRole('button', { name: 'Confirm' }), 'because the owner confirms a spec recap, not a plan').not.toBeNull();
});

test('InterviewGateWithNumberedQuestions_QuestionsShown', () => {
  renderGate({ ...waitingGate('gh#601', 'interview'), message: '**Confirm the spec recap, or say what to change.**\n\nOpen questions:\n1. Should the drill time out? Recommended: after 30s.', questions: [] });
  expect(screen.queryByText(/Should the drill time out\?/), 'because a verdict gate has no question form, so dropping the list would hide what the owner confirms').not.toBeNull();
});

test('FeelTest_SignOff_PostsSignedOff', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate({ ...waitingGate('gh#577', 'feel-test'), questions: [] }, daemon);
  await press('Sign off');
  expect(posted, 'because a build that feels right needs no words').toEqual([{ kind: 'gate.clear', args: { item: 'gh#577', message: 'Signed off. It feels right.' } }]);
});

test('FeelTest_ReportProblems_SendsTheBuildBack', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate({ ...waitingGate('gh#577', 'feel-test'), questions: [] }, daemon);
  await press('Report problems…');
  fireEvent.change(screen.getByLabelText('What should change?'), { target: { value: 'The hold feels slow.' } });
  await press('Report problems');
  expect(posted, 'because a problem found by hand sends the work back to implement').toEqual([{ kind: 'gate.clear', args: { item: 'gh#577', message: 'The hold feels slow.', back: 'true' } }]);
});

test('Answers_SendsTheRecommendationAndTheOwnersWords', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(ASKING, daemon);
  fireEvent.change(screen.getByLabelText('Your answer to question 2'), { target: { value: 'No.' } });
  await press('Send answers');
  expect(posted[0], 'because gate.clear posts each numbered answer').toEqual({ kind: 'gate.clear', args: { item: 'gh#504', message: '1. the ball misses the target.\n2. No.' } });
});

test('Answering_CardSaysSoAtOnce', async () => {
  const { daemon } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  await press('Approve');
  expect(screen.queryByText(/posting your answer and clearing the gate…/), 'because the owner should see the press landed before the gate clears').not.toBeNull();
});

test('Answering_StartsTheRunOnlyOnceTheGateCleared', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  act(() => { daemon.latestStream().open(); });
  await press('Approve');
  expect(posted.map((action) => action.kind), 'because next.sh would find the gate still raised').toEqual(['gate.clear']);
  await clearEnds(daemon, 'done');
  expect(posted.at(-1), 'because the run continues the item the owner just unblocked').toEqual({ kind: 'run.start', args: { item: 'gh#514' } });
});

test('LeftGatesBeforeTheClearEnded_RunStillStarts', async () => {
  const { daemon, posted } = recordingDaemon();
  const Wrapper = daemon.screenWrapper();
  const gates = <Gates snapshot={{ ...snapshotAt(TAKEN_AT, 1), gates: [PLAN_GATE] }} selected={PLAN_GATE.item} />;
  const view = render(<Wrapper>{gates}</Wrapper>);
  act(() => { daemon.latestStream().open(); });
  await press('Approve');
  view.rerender(<Wrapper>{null}</Wrapper>);
  await clearEnds(daemon, 'done');
  expect(posted.at(-1), 'because the owner may move on while the gate clears, and the item must not sit idle').toEqual({ kind: 'run.start', args: { item: 'gh#514' } });
});

test('RunRefusedForTheQueue_SaysTheScheduledRunPicksItUp', async () => {
  const { daemon } = recordingDaemon(true);
  renderGate(PLAN_GATE, daemon, { jobs: [NEXT_JOB] });
  act(() => { daemon.latestStream().open(); });
  await press('Approve');
  await clearEnds(daemon, 'done');
  expect(screen.queryByText(/the next scheduled run picks up gh#514 \(18:30\)/), 'because a busy queue is not a failure, only a wait').not.toBeNull();
});

test('ClearFailed_NoRunAndTheNotesComeBack', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate(PLAN_GATE, daemon);
  act(() => { daemon.latestStream().open(); });
  await press('Send back…');
  fireEvent.change(screen.getByLabelText('What should change?'), { target: { value: 'Add a rollback phase.' } });
  await press('Send back');
  await clearEnds(daemon, 'failed');
  await press('Back to my answer');
  expect(posted.map((action) => action.kind), 'because a gate that did not clear must not start a run').toEqual(['gate.clear']);
  expect((screen.getByLabelText('What should change?') as HTMLTextAreaElement).value, 'because the owner should not retype a failed answer').toBe('Add a rollback phase.');
});

test('MergeGateWithAMergeablePull_MergesItAndStartsNoRun', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: { ...PULL, state: 'mergeable', unresolvedThreads: 0 } }, daemon);
  act(() => { daemon.latestStream().open(); });
  await press('Merge PR #560');
  await act(async () => { daemon.latestStream().send('action', { ...actionRecord('a1', 'done', {}), kind: 'pr.merge', outcome: 'finished' }); });
  expect(posted, 'because the sweep clears a merge gate once the PR is merged').toEqual([{ kind: 'pr.merge', args: { pr: '560' } }]);
});

test('MergeGateWithAFailingPull_NoMergeButton', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.queryByRole('button', { name: 'Merge PR #560' }), 'because failing checks must not be merged from a button').toBeNull();
});

test('GateWithASessionOnItsItem_OffersDiscuss', () => {
  const ended: EndedAgent = { pid: 200, host: 'claude', kind: 'agent', cwd: '/p-wt/wt-3', worktree: 'wt-3', item: 'gh#514', elapsedSeconds: 60, command: 'claude -p', session: { host: 'claude', id: '8f3c', transcript: '/h/8f3c.jsonl', resume: ['claude', '--resume', '8f3c'] }, endedAt: TAKEN_AT };
  renderGate(PLAN_GATE, new FakeDaemon(), { ended: [ended] });
  expect(screen.queryByRole('button', { name: 'Discuss with the agent' }), 'because the owner may want to talk the plan through before deciding').not.toBeNull();
});

test('GateWithNoSession_NoDiscuss', () => {
  renderGate(PLAN_GATE);
  expect(screen.queryByRole('button', { name: 'Discuss with the agent' }), 'because there is no session to resume').toBeNull();
});

const ANSWERED_NOW = new Date().toISOString();

test('AnsweredEventToday_ListedUnderAnsweredToday', () => {
  renderGate(PLAN_GATE, new FakeDaemon(), { events: [{ at: ANSWERED_NOW, item: 'gh#213', kind: 'answered', message: 'ambiguity: go with option b3' }] });
  expect(screen.getByRole('link', { name: /gh#213 ambiguity · “go with option b3”/ }).getAttribute('href'), 'because an answer from a terminal or before a reload still counts as answered today').toContain('activity');
});

test('AnsweredEventYesterday_NotListed', () => {
  const yesterday = new Date(Date.now() - 2 * 24 * 3600 * 1000).toISOString();
  renderGate(PLAN_GATE, new FakeDaemon(), { events: [{ at: yesterday, item: 'gh#213', kind: 'answered', message: 'ambiguity: go with option b3' }] });
  expect(screen.queryByText(/go with option b3/), 'because the panel is for today only').toBeNull();
});

test('NoAnswerToday_PanelSaysSo', () => {
  renderGate(PLAN_GATE, new FakeDaemon(), { events: [{ at: ANSWERED_NOW, item: 'gh#213', kind: 'ambiguity', message: 'A raised gate, not an answer' }] });
  expect(screen.queryByText('Nothing answered yet today.'), 'because the panel stays, so the owner knows where answers will show').not.toBeNull();
});

test('AnsweredHereAndLogged_ListedOnce', async () => {
  const { daemon } = recordingDaemon();
  const Wrapper = daemon.screenWrapper();
  const view = render(<Wrapper><Gates snapshot={{ ...snapshotAt(TAKEN_AT, 1), gates: [PLAN_GATE] }} selected={PLAN_GATE.item} /></Wrapper>);
  await press('Approve');
  view.rerender(<Wrapper><Gates snapshot={{ ...snapshotAt(TAKEN_AT, 2), gates: [], events: [{ at: new Date().toISOString(), item: 'gh#514', kind: 'answered', message: 'plan-approval: Approved.' }] }} selected={PLAN_GATE.item} /></Wrapper>);
  expect(screen.getAllByText(/gh#514 plan-approval ·/), 'because the logged line is the same answer as the one given here').toHaveLength(1);
});
