import { useState } from 'react';
import type { Agent, Gate, GateQuestion, LabelGate, ReadyToClose, Snapshot } from '../../../daemon/src/snapshot.ts';
import { ExternalLink, trackerUrl } from '../links.tsx';
import { Age, formatDuration } from '../clock.tsx';
import { gateKey, useGateAnswers } from '../gateAnswers.tsx';
import type { Answered, Decision, Draft, Said, Step } from '../gateAnswers.tsx';
import { choiceAnswers, composeGateMessage, gateAsk, gateBrief, initialChoices, ownGates, verdictMessage } from '../gateAnswer.ts';
import type { GateChoice, OwnGate, Verdict } from '../gateAnswer.ts';
import { AskReview } from '../askReview.tsx';
import { Markdown } from '../Markdown.tsx';
import { QuizPanel } from '../Quiz.tsx';
import { routeHash } from '../route.ts';
import type { ActionRecord } from '../actions.ts';
import { pullTone } from '../status.ts';
import { GATE_KINDS } from '../words.ts';
import { ActionButton, Chip, Dot, Empty, useActionsView } from '../ui.tsx';
import { OptionsForm } from './GateOptions.tsx';
import { GateFooter, GateRoles, TwinNote, twinCount } from './GateRoles.tsx';

/** How a gate is answered: a verdict on a plan or a spec, a verdict on a build, answers to questions, or a merge. */
type GateForm = 'approval' | 'feel' | 'answers' | 'merge';

function formOf(gate: Gate): GateForm {
  if (gate.gate === 'plan-approval' || gate.gate === 'decomposition' || gate.gate === 'interview') return 'approval';
  if (gate.gate === 'feel-test') return 'feel';
  if (gate.gate === 'merge') return 'merge';
  return 'answers';
}

/** The decision each gate asks for, for a message written before gates led with one. */
const DEFAULT_ASKS: Record<string, string> = {
  interview: 'Confirm the spec recap, or say what to change.',
  'plan-approval': 'Approve the plan, approve it with notes, or send it back.',
  decomposition: 'Approve the split, or send it back.',
  'feel-test': 'Launch it and sign off, or report what feels wrong.',
  merge: 'Merge the pull request.',
  escalation: 'Say what the agent should do.',
  ambiguity: 'Answer the questions.',
};

/** What sending a gate back does, per gate: the step that runs again. */
const SEND_BACK_HELP: Record<string, string> = {
  interview: 'The interview runs again, with your notes.',
  'plan-approval': 'The plan is written again, with your notes.',
  decomposition: 'The split is planned again, with your notes.',
  'feel-test': 'The implement step runs again, with your notes.',
};

/** A gate waiting this long is late (amber), and this long, overdue (red); the age bar fills at the last. */
const LATE_HOURS = 24;
const OLD_HOURS = 48;
const FULL_BAR_HOURS = 72;
const SECONDS_PER_HOUR = 3600;

/** A summary this long or shorter sits in the card head; a longer one is folded in the body. */
const SHORT_SUMMARY_CHARS = 600;

export function Gates({ snapshot, selected }: { snapshot: Snapshot; selected: string | null }) {
  const { answered, drafts, answer, retry } = useGateAnswers();
  const isAnswered = (gate: Gate): boolean => answered[gate.item]?.gate.raisedAt === gate.raisedAt;
  const unanswered = snapshot.gates.filter((gate) => !isAnswered(gate));
  const waiting = ownGates(unanswered).sort((left, right) => right.gate.ageSeconds - left.gate.ageSeconds);
  const done = Object.values(answered).filter((entry) => !unanswered.some((gate) => gate.item === entry.gate.item)).sort((left, right) => right.at.getTime() - left.at.getTime());
  const toClose = snapshot.toClose;
  const labelGates = snapshot.labelGates;
  const pick = selected ?? waiting[0]?.gate.item ?? toClose[0]?.item ?? labelGates[0]?.item ?? done[0]?.gate.item ?? null;
  const answersItem = (row: OwnGate): boolean => row.gate.item === pick || row.twins.some((twin) => twin.item === pick);
  const current = waiting.find(answersItem);
  // An item to close now outranks an answer this console still holds for it: a split's
  // decomposition gate answered here is followed, once its children close, by its close card.
  const closing = current === undefined ? toClose.find((entry) => entry.item === pick) : undefined;
  const labelled = current === undefined && closing === undefined ? labelGates.find((entry) => entry.item === pick) : undefined;
  const answeredCurrent = current === undefined && closing === undefined && labelled === undefined ? done.find((entry) => entry.gate.item === pick) : undefined;
  const nextGate = waiting.find((row) => row !== current && row.gate.item !== pick)?.gate ?? null;

  return (
    <div className="screen">
      <div className="gates">
        <section className="gate-picks" aria-label="Waiting gates">
          {waiting.length === 0 && <div className="gate-panel"><Empty>No gate waits on you.</Empty></div>}
          {waiting.map((row) => <GatePick key={row.gate.item} row={row} snapshot={snapshot} selected={row === current} />)}
          {toClose.length > 0 && (
            <div className="gate-panel close-list" aria-label="Ready to close">
              <h3>Ready to close <span className="muted">{toClose.length}</span></h3>
              <p className="muted">No flow gate asks about these, and the next job never takes them again: they wait for you.</p>
              {toClose.map((entry) => <ClosePick key={entry.item} entry={entry} snapshot={snapshot} selected={entry.item === pick} />)}
            </div>
          )}
          {labelGates.length > 0 && (
            <div className="gate-panel close-list" aria-label="Label only">
              <h3>Label only <span className="muted">{labelGates.length}</span></h3>
              <p className="muted">A tracker label gates these, but no gate was raised, so no question waits: record one or remove the label.</p>
              {labelGates.map((entry) => <LabelGatePick key={entry.item} entry={entry} snapshot={snapshot} selected={entry.item === pick} />)}
            </div>
          )}
          <AnsweredToday snapshot={snapshot} done={done} pick={pick} />
        </section>
        {current !== undefined && (
          <DecisionCard key={gateKey(current.gate)} gate={current.gate} twins={current.twins} snapshot={snapshot} draft={drafts[gateKey(current.gate)] ?? null}
            onAnswer={(decision, draft) => answer(current.gate, current.twins, decision, draft)} />
        )}
        {answeredCurrent !== undefined && (
          <AnsweredCard entry={answeredCurrent} twins={answeredWith(answeredCurrent, Object.values(answered))} snapshot={snapshot} nextGate={nextGate} onRetry={() => retry(answeredCurrent)} />
        )}
        {closing !== undefined && <CloseCard entry={closing} snapshot={snapshot} />}
        {labelled !== undefined && <LabelGateCard entry={labelled} snapshot={snapshot} />}
        {current === undefined && answeredCurrent === undefined && closing === undefined && labelled === undefined && pick !== null && (
          <section className="decision-card" aria-label="Decision card">
            <Empty>That gate was cleared. {waiting.length > 0 ? 'Pick another from the list.' : 'Nothing else waits on you.'}</Empty>
          </section>
        )}
      </div>
    </div>
  );
}

/** The twins answered in the same go as a gate, each with its own clear. */
function answeredWith(entry: Answered, all: Answered[]): Answered[] {
  return all.filter((other) => other.gate.twinOf === entry.gate.item && other.at.getTime() === entry.at.getTime());
}

/** A row of the answered list: when, which gate, and what was said; `local` rows open their answered card. */
type AnsweredRow = { at: Date; item: string; gate: string; said: string; local: boolean };

/** How long before a local answer its events.log line may be stamped and still be the same answer. */
const SAME_ANSWER_MS = 60_000;

/**
 * Gates answered today, newest first: the `answered` lines gate.sh writes to events.log, which
 * outlive a reload and include answers given in a terminal, and the answers given here, which
 * show at once and open their card.
 */
function AnsweredToday({ snapshot, done, pick }: { snapshot: Snapshot; done: Answered[]; pick: string | null }) {
  const projectId = snapshot.project.id;
  const today = new Date().toDateString();
  const local: AnsweredRow[] = done.map((entry) => ({ at: entry.at, item: entry.gate.item, gate: entry.gate.gate, said: quoteOf(entry.said), local: true }));
  const logged: AnsweredRow[] = snapshot.events.filter((event) => event.kind === 'answered' && event.item !== null).map((event) => {
    const split = event.message.indexOf(': ');
    const gate = split < 0 ? event.message : event.message.slice(0, split);
    const said = split < 0 ? '' : event.message.slice(split + 2).trim();
    return { at: new Date(event.at), item: event.item!, gate, said: said === '' ? 'answered' : `“${said}”`, local: false };
  }).filter((row) => !local.some((mine) => mine.item === row.item && row.at.getTime() >= mine.at.getTime() - SAME_ANSWER_MS));
  const rows = [...local, ...logged].filter((row) => row.at.toDateString() === today).sort((left, right) => right.at.getTime() - left.at.getTime());
  return (
    <div className="gate-panel answered-list">
      <h3>Answered today</h3>
      {rows.length === 0 && <p className="muted">Nothing answered yet today.</p>}
      {rows.map((row) => (
        <a key={`${row.item}:${row.at.getTime()}`} className={row.local && row.item === pick ? 'answered-row selected' : 'answered-row'}
          href={routeHash(row.local ? { projectId, screen: 'gates', detail: row.item } : { projectId, screen: 'activity', detail: row.item })}>
          <span className="mono">{hourMinute(row.at)}</span>
          <span>{row.item} {row.gate} · {row.said}</span>
        </a>
      ))}
    </div>
  );
}

/** What the Gates screen lists: the gates, the items to close and the label-only gates, the same set the Overview's needs-you count counts. */
export function waitingOnYou(snapshot: Snapshot): number {
  return ownGates(snapshot.gates).length + snapshot.toClose.length + snapshot.labelGates.length;
}

/** The count and the line beside the page title on the Gates screen. */
export function GatesHeading({ snapshot }: { snapshot: Snapshot }) {
  return (
    <>
      <span className="badge tone-needs-you">{waitingOnYou(snapshot)} waiting</span>
      <span className="page-note">Pick one. Your answer goes on the issue and the run continues.</span>
    </>
  );
}

/** How late a gate is: a tone for its age and how full its age bar is. */
function lateness(gate: Gate): { tone: 'fresh' | 'late' | 'old'; percent: number } {
  const hours = gate.ageSeconds / SECONDS_PER_HOUR;
  const tone = gate.overdue || hours >= OLD_HOURS ? 'old' : hours >= LATE_HOURS ? 'late' : 'fresh';
  return { tone, percent: Math.min(hours / FULL_BAR_HOURS, 1) * 100 };
}

/** The last folder of a worktree path, the name the pool uses. */
function worktreeName(path: string | null): string | null {
  if (path === null) return null;
  return path.split('/').filter((part) => part !== '').at(-1) ?? path;
}

/** One waiting gate in the list: its kind, item, age, title, worktree and step, and an age bar; a twin row says how many items it answers. */
function GatePick({ row, snapshot, selected }: { row: OwnGate; snapshot: Snapshot; selected: boolean }) {
  const gate = row.gate;
  const item = snapshot.items.find((entry) => entry.id === gate.item);
  const { tone, percent } = lateness(gate);
  const twins = twinCount(row.twins);
  return (
    <a className={selected ? 'gate-pick selected' : 'gate-pick'} href={routeHash({ projectId: snapshot.project.id, screen: 'gates', detail: gate.item })} aria-current={selected ? 'true' : undefined}>
      <span className="gate-pick-line">
        <Chip tone="needs-you">{gate.gate}</Chip>
        <span className="mono muted">{gate.item}</span>
        {twins !== null && <span className="gate-twins">{twins}</span>}
        <span className={`gate-age ${tone}`}><Age seconds={gate.ageSeconds} takenAt={snapshot.takenAt} /></span>
      </span>
      <span className="gate-pick-title">{item?.title ?? gate.item}</span>
      <span className="gate-pick-foot">
        <span>{worktreeName(gate.worktree) ?? 'no worktree'} · {item?.step ?? 'step unknown'}</span>
        <span className="age-bar"><span className={tone} style={{ width: `${percent}%` }} /></span>
      </span>
    </a>
  );
}

/** One item to close in the list: its chip, item, how long since its last event, title, and what to do. */
function ClosePick({ entry, snapshot, selected }: { entry: ReadyToClose; snapshot: Snapshot; selected: boolean }) {
  return (
    <a className={selected ? 'gate-pick selected' : 'gate-pick'} href={routeHash({ projectId: snapshot.project.id, screen: 'gates', detail: entry.item })} aria-current={selected ? 'true' : undefined}>
      <span className="gate-pick-line">
        <Chip tone="needs-you">close</Chip>
        <span className="mono muted">{entry.item}</span>
        {entry.ageSeconds !== null && <span className="gate-age fresh"><Age seconds={entry.ageSeconds} takenAt={snapshot.takenAt} /></span>}
      </span>
      <span className="gate-pick-title">{entry.title || entry.item}</span>
      <span className="gate-pick-foot"><span>{entry.todo}</span></span>
    </a>
  );
}

/** Why the item is the owner's to finish, beyond the one-line to-do. */
const CLOSE_WHY: Record<ReadyToClose['reason'], string> = {
  'children-closed': 'It was split into tracker tasks and every one of them is closed, so the parent has nothing left to run.',
  'steps-done': 'Every step of the flow ran and no merge gate is up, so the next job will not take it again.',
};

/**
 * An item to close: what to do and why, its open PR (with a merge button once it is ready), and its
 * issue, where it is closed. No flow gate exists for it, so nothing here clears one.
 */
function CloseCard({ entry, snapshot }: { entry: ReadyToClose; snapshot: Snapshot }) {
  const projectId = snapshot.project.id;
  const item = snapshot.items.find((each) => each.id === entry.item);
  const facts = [
    entry.ageSeconds === null ? null : `last event ${formatDuration(entry.ageSeconds)} ago`,
    item !== undefined && item.size !== '' ? `size ${item.size}` : null,
    item !== undefined && item.step !== '' ? `step ${item.step}` : null,
  ].filter((fact): fact is string => fact !== null);
  const pull = entry.pull;
  return (
    <section className="decision-card" aria-label="Close card">
      <div className="decision-head">
        <div className="decision-head-line">
          <Chip tone="needs-you">ready to close</Chip>
          <span className="mono muted">{entry.item}</span>
          <span className="decision-links">
            <ExternalLink url={entry.url ?? trackerUrl(snapshot, entry.item)} className="">Issue</ExternalLink>
            {entry.worktree !== null && <a href={routeHash({ projectId, screen: 'worktrees', detail: null })}>{entry.worktree}</a>}
          </span>
        </div>
        <h2>{entry.title || entry.item}</h2>
        {facts.length > 0 && <div className="facts">{facts.map((fact) => <span key={fact} className="fact">{fact}</span>)}</div>}
      </div>
      <div className="decision-body">
        {pull !== null && <GatePull pull={pull} />}
        <div className="decision">
          <fieldset className="question">
            <legend>{entry.todo}</legend>
            <p className="muted decision-help">{CLOSE_WHY[entry.reason]} No gate asks about it: close it on the tracker{entry.reason === 'steps-done' ? ' once its PR is merged, or close it unmerged' : ''}.</p>
            <div className="decision-actions">
              {pull !== null && pull.state === 'mergeable' && <ActionButton kind="pr.merge" args={{ pr: String(pull.number) }} label={`Merge #${pull.number}`} primary />}
              <ExternalLink url={entry.url ?? trackerUrl(snapshot, entry.item)} className="button">Open the issue</ExternalLink>
            </div>
          </fieldset>
        </div>
      </div>
    </section>
  );
}

/** One item gated only by a tracker label: its gate, item, how long since its last event, title, and worktree. */
function LabelGatePick({ entry, snapshot, selected }: { entry: LabelGate; snapshot: Snapshot; selected: boolean }) {
  return (
    <a className={selected ? 'gate-pick selected' : 'gate-pick'} href={routeHash({ projectId: snapshot.project.id, screen: 'gates', detail: entry.item })} aria-current={selected ? 'true' : undefined}>
      <span className="gate-pick-line">
        <Chip tone="needs-you">{entry.gate}</Chip>
        <span className="mono muted">{entry.item}</span>
        {entry.ageSeconds !== null && <span className="gate-age fresh"><Age seconds={entry.ageSeconds} takenAt={snapshot.takenAt} /></span>}
      </span>
      <span className="gate-pick-title">{entry.title || entry.item}</span>
      <span className="gate-pick-foot"><span>{entry.worktree ?? 'no worktree'} · no question recorded</span></span>
    </a>
  );
}

/** The two ways out of a label-only gate: record it with a question, or drop the label. */
function labelGateHint(entry: LabelGate): string {
  return `gate.sh raise ${entry.item} ${entry.gate} "<message>" to record it, or remove the gate:${entry.gate} label on the tracker`;
}

/**
 * An item a tracker label gates with no gate record behind it: the gate, the item and its age, and
 * the two ways out. No question was recorded, so there is nothing to answer here.
 */
function LabelGateCard({ entry, snapshot }: { entry: LabelGate; snapshot: Snapshot }) {
  const projectId = snapshot.project.id;
  const url = entry.url ?? trackerUrl(snapshot, entry.item);
  return (
    <section className="decision-card" aria-label="Label gate card">
      <div className="decision-head">
        <div className="decision-head-line">
          <Chip tone="needs-you">{entry.gate}</Chip>
          <span className="mono muted">{entry.item}</span>
          <span className="decision-links">
            <ExternalLink url={url} className="">Issue</ExternalLink>
            {entry.worktree !== null && <a href={routeHash({ projectId, screen: 'worktrees', detail: null })}>{entry.worktree}</a>}
          </span>
        </div>
        <h2>{entry.title || entry.item}</h2>
        {entry.ageSeconds !== null && <div className="facts"><span className="fact">last event {formatDuration(entry.ageSeconds)} ago</span></div>}
      </div>
      <div className="decision-body">
        <div className="decision">
          <fieldset className="question">
            <legend>{entry.gate} gate, label only</legend>
            <p className="muted decision-help">The question text is not recorded: this gate is only a tracker label, set without gate.sh raise.</p>
            <p className="command-hint mono">{labelGateHint(entry)}</p>
            <div className="decision-actions">
              <ExternalLink url={url} className="button">Open the issue</ExternalLink>
            </div>
          </fieldset>
        </div>
      </div>
    </section>
  );
}

/** The card head: kind, item and links, the title, the facts, and the agent's summary when it is short. */
function DecisionHead({ gate, snapshot, answered, summary }: { gate: Gate; snapshot: Snapshot; answered: boolean; summary: string | null }) {
  const item = snapshot.items.find((entry) => entry.id === gate.item);
  const projectId = snapshot.project.id;
  const wt = worktreeName(gate.worktree);
  const waitingFact = answered ? null : `waiting ${formatDuration(gate.ageSeconds)}`;
  const facts = [
    `raised ${raisedAt(gate.raisedAt)}`,
    waitingFact,
    item !== undefined && item.size !== '' ? `size ${item.size}` : null,
    item !== undefined && item.step !== '' ? `step ${item.step}` : null,
    gate.questions.length > 1 ? `${gate.questions.length} questions` : null,
    gate.plan !== null ? gate.plan.file.split('/').at(-1) ?? null : null,
    gate.quiz === null ? null : gate.quiz.result?.passed === true ? 'quiz passed' : `quiz: ${gate.quiz.questions.length} ${gate.quiz.questions.length === 1 ? 'question' : 'questions'}`,
  ].filter((fact): fact is string => fact !== null);
  return (
    <div className="decision-head">
      <div className="decision-head-line">
        {answered ? <Chip tone="running">answered</Chip> : <Chip tone="needs-you">{gate.gate}</Chip>}
        <span className="mono muted">{gate.item}</span>
        <span className="decision-links">
          <ExternalLink url={trackerUrl(snapshot, gate.item)} className="">Issue</ExternalLink>
          {wt !== null && <a href={routeHash({ projectId, screen: 'worktrees', detail: null })}>{wt}</a>}
          <a href={routeHash({ projectId, screen: 'agents', detail: null })}>Run log</a>
        </span>
      </div>
      <h2>{item?.title ?? gate.item}</h2>
      <div className="facts">{facts.map((fact) => <span key={fact} className={gate.overdue && fact === waitingFact ? 'fact overdue' : 'fact'}>{fact}</span>)}</div>
      <GateRoles gate={gate} />
      {summary !== null && <Markdown className="decision-summary" text={summary} />}
    </div>
  );
}

/** The props of a decision card: the gate, the twins its answer also clears, and what the owner had typed. */
type DecisionCardProps = { gate: Gate; twins: Gate[]; snapshot: Snapshot; draft: Draft | null; onAnswer: (decision: Decision, draft: Draft) => void };

/** One gate as a decision: what it is about, and the answers that fit this kind of gate. */
export function DecisionCard({ gate, twins, snapshot, draft, onAnswer }: DecisionCardProps) {
  const form = formOf(gate);
  const choosing = form === 'answers' && gate.options.length > 0;
  const asksNumberedQuestions = form === 'answers' && !choosing;
  const { brief, numbered } = asksNumberedQuestions ? gateBrief(gate.message) : { brief: gate.message.trim(), numbered: false };
  const { ask: written, rest } = gateAsk(brief);
  const ask = written ?? DEFAULT_ASKS[gate.gate] ?? GATE_KINDS[gate.gate] ?? 'Answer the gate.';
  // Answers lead with the ask in the head; a verdict or a merge asks it over its buttons.
  const summary = (form === 'answers' ? [`**${ask}**`, rest] : [rest]).filter((part) => part.trim() !== '').join('\n\n');
  const short = summary.length <= SHORT_SUMMARY_CHARS;
  const lead = form === 'approval' ? (gate.plan !== null ? 'plan' : gate.body !== null && gate.body.trim() !== '' ? 'issue' : null) : null;
  const discuss = discussArgs(snapshot, gate);
  return (
    <section className="decision-card" aria-label="Decision card">
      <DecisionHead gate={gate} snapshot={snapshot} answered={false} summary={short && summary !== '' ? summary : null} />
      <div className="decision-body">
        {gate.pull !== null && <GatePull pull={gate.pull} />}
        {gate.quiz !== null && <QuizPanel item={gate.item} quiz={gate.quiz} />}
        {!short && <GateDocument title="The agent's summary" file={null} text={summary} open={false} />}
        {lead === 'plan' && gate.plan !== null && <GateDocument title="Plan" file={gate.plan.file} text={gate.plan.text} open />}
        {lead === 'issue' && gate.body !== null && <GateDocument title="Spec" file={null} text={gate.body} open />}
        {lead !== 'plan' && gate.plan !== null && <GateDocument title="Plan" file={gate.plan.file} text={gate.plan.text} open={false} />}
        {lead !== 'issue' && gate.body !== null && gate.body.trim() !== '' && <GateDocument title="Issue" file={null} text={gate.body} open={false} />}
        {(form === 'approval' || form === 'feel') && <VerdictForm gate={gate} ask={ask} form={form} split={isSplit(gate, snapshot)} draft={draft} onAnswer={onAnswer} />}
        <TwinNote gate={gate} twins={twins} />
        {choosing && <OptionsForm gate={gate} hint={commandHint(gate, false)} draft={draft} onAnswer={onAnswer} />}
        {asksNumberedQuestions && <AnswersForm gate={gate} questions={numbered ? gate.questions : []} draft={draft} onAnswer={onAnswer} />}
        {form === 'merge' && <MergeForm gate={gate} ask={ask} reviewers={snapshot.project.reviewers} onAnswer={onAnswer} />}
        <GateFooter gate={gate} />
        {discuss !== null && (
          <div className="gate-discuss">
            <ActionButton kind="terminal.open" args={discuss} label="Discuss with the agent" primary={false}
              title="Opens a terminal at the worktree and resumes the session that raised this gate, so you can talk it through before you answer." />
            <span className="muted">Resumes the session that raised the gate, in a terminal.</span>
          </div>
        )}
      </div>
    </section>
  );
}

/**
 * How to open the session to discuss the gate with: the newest agent on the item with a session,
 * running or ended, by its pid; else the session the daemon located for the gate from the
 * transcripts on disk (it survives a daemon restart), by the gate's item. Null with neither.
 */
function discussArgs(snapshot: Snapshot, gate: Gate): Record<string, string> | null {
  const agent = latestSession(snapshot, gate.item);
  if (agent !== null) return { path: agent.cwd, session: String(agent.pid) };
  return gate.session !== null ? { gate: gate.item } : null;
}

/** The newest session that worked on the item, running or ended, so the owner can talk to it. */
function latestSession(snapshot: Snapshot, item: string): Agent | null {
  const running = snapshot.agents.filter((agent) => agent.item === item && agent.session !== null);
  if (running.length > 0) return running[0]!;
  const ended = snapshot.ended.filter((agent) => agent.item === item && agent.session !== null).sort((left, right) => right.endedAt.localeCompare(left.endedAt));
  return ended[0] ?? null;
}

/** The commands an answer runs, as the card shows them under its buttons. */
function commandHint(gate: Gate, back: boolean): string {
  const where = worktreeName(gate.worktree);
  return `gate.sh clear${back ? ' --back' : ''} → next.sh ${gate.item}${where === null ? '' : ` in ${where}`}`;
}

/** The labels of a verdict gate: an approval of a plan or a spec, or a sign-off of a build. */
function verdictWords(gate: Gate, form: 'approval' | 'feel') {
  if (form === 'feel') return { yes: 'Sign off', yesVerdict: 'sign-off' as const, notes: null, no: 'Report problems', noVerdict: 'report' as const };
  const yes = gate.gate === 'interview' ? 'Confirm' : 'Approve';
  return { yes, yesVerdict: 'approve' as const, notes: `${yes} with notes`, no: 'Send back', noVerdict: 'send-back' as const };
}

const VERBS: Record<Verdict, string> = {
  approve: 'Approved',
  'approve-notes': 'Approved with notes',
  'send-back': 'Sent back',
  'sign-off': 'Signed off',
  report: 'Problems reported',
};

/** A decomposition gate on an item already split into tracker tasks, which gate.sh will not send back. */
function isSplit(gate: Gate, snapshot: Snapshot): boolean {
  return gate.gate === 'decomposition' && snapshot.items.find((entry) => entry.id === gate.item)?.step === 'split';
}

/** What keeps a split item whole: gate.sh refuses to send it back, but clearing with its children closed runs the plan step again. */
const KEEP_WHOLE_HELP = 'It is already split into tracker tasks, so it cannot be sent back. To keep it whole, close its child issues, then approve: the plan step runs again.';

/**
 * Approve, approve with notes, or send back; or sign off, or report problems. Notes are asked for
 * only when they are needed. A split item has no send back.
 */
function VerdictForm({ gate, ask, form, split, draft, onAnswer }: { gate: Gate; ask: string; form: 'approval' | 'feel'; split: boolean; draft: Draft | null; onAnswer: (decision: Decision, draft: Draft) => void }) {
  const words = verdictWords(gate, form);
  const [mode, setMode] = useState<Verdict | null>(draft?.mode ?? null);
  const [notes, setNotes] = useState(draft?.note ?? '');
  const send = (verdict: Verdict): void => {
    const { message, back } = verdictMessage(verdict, notes);
    onAnswer({ kind: 'clear', message, back, said: { verb: VERBS[verdict], message } }, { choices: [], note: notes, mode: verdict });
  };
  const back = SEND_BACK_HELP[gate.gate] ?? 'The step runs again, with your notes.';
  const asking = mode !== null && mode !== words.yesVerdict;
  const sendBack = mode !== 'approve-notes';
  return (
    <form className="decision" onSubmit={(event) => { event.preventDefault(); if (asking && notes.trim() !== '') send(mode); }}>
      <fieldset className="question">
        <legend>{ask}</legend>
        {!asking ? (
          <>
            <div className="decision-actions">
              <button type="button" className="button primary" onClick={() => send(words.yesVerdict)}>{words.yes}</button>
              {words.notes !== null && <button type="button" className="button" onClick={() => setMode('approve-notes')}>{words.notes}…</button>}
              {!split && <button type="button" className="button" onClick={() => setMode(words.noVerdict)}>{words.no}…</button>}
            </div>
            <p className="muted decision-help">{words.yes} continues the run. {split ? KEEP_WHOLE_HELP : back}</p>
          </>
        ) : (
          <>
            <label className="field">
              <span>{sendBack ? 'What should change?' : 'Your notes for the agent'}</span>
              <textarea rows={3} autoFocus required value={notes} onChange={(event) => setNotes(event.target.value)}
                placeholder={sendBack ? 'Say what is wrong and what you want instead.' : 'The agent reads these before the next step.'} />
            </label>
            <div className="decision-actions">
              <button type="submit" className={sendBack ? 'button primary danger' : 'button primary'} disabled={notes.trim() === ''}>{sendBack ? words.no : words.notes ?? words.yes}</button>
              <button type="button" className="button" onClick={() => setMode(null)}>Cancel</button>
              <span className="muted">{sendBack ? back : 'The run continues to the next step.'}</span>
            </div>
          </>
        )}
      </fieldset>
      <p className="command-hint mono">{commandHint(gate, asking && sendBack)}</p>
    </form>
  );
}

/** Questions with the recommendation picked, a note, and one send; or one answer box when the gate asks no numbered questions. */
function AnswersForm({ gate, questions, draft, onAnswer }: { gate: Gate; questions: GateQuestion[]; draft: Draft | null; onAnswer: (decision: Decision, draft: Draft) => void }) {
  const [choices, setChoices] = useState<GateChoice[]>(() => draft?.choices ?? initialChoices(questions));
  const [note, setNote] = useState(draft?.note ?? '');
  const message = composeGateMessage(choiceAnswers(questions, choices), note);
  const ready = questions.length === 0 ? note.trim() !== '' : choiceAnswers(questions, choices).every((entry) => entry.answer.trim() !== '');
  const setChoice = (number: number, update: Partial<GateChoice>): void => setChoices((all) => all.map((entry) => (entry.number === number ? { ...entry, ...update } : entry)));
  const send = (): void => onAnswer({ kind: 'clear', message, back: false, said: { verb: 'Answered', message } }, { choices, note, mode: null });
  return (
    <form className="decision" onSubmit={(event) => { event.preventDefault(); if (ready) send(); }}>
      {questions.map((question) => {
        const choice = choices.find((entry) => entry.number === question.number);
        const name = `gate-${gate.item}-q${question.number}`;
        return (
          <fieldset key={question.number} className="question">
            <legend><span className="question-number">{question.number}.</span> <Markdown className="question-text" text={question.text} /></legend>
            {question.recommended === null ? (
              <textarea aria-label={`Your answer to question ${question.number}`} rows={2} value={choice?.other ?? ''} onChange={(event) => setChoice(question.number, { other: event.target.value })} />
            ) : (
              <>
                <label className={choice?.pick === 'recommended' ? 'option picked' : 'option'}>
                  <input type="radio" name={name} checked={choice?.pick === 'recommended'} onChange={() => setChoice(question.number, { pick: 'recommended' })} />
                  <span className="option-text"><span className="recommended">Recommended · </span><Markdown text={question.recommended} /></span>
                </label>
                <label className={choice?.pick === 'other' ? 'option picked' : 'option'}>
                  <input type="radio" name={name} checked={choice?.pick === 'other'} onChange={() => setChoice(question.number, { pick: 'other' })} />
                  <span className="option-text">Something else</span>
                </label>
                {choice?.pick === 'other' && (
                  <textarea aria-label={`Your answer to question ${question.number}`} rows={2} autoFocus value={choice.other} onChange={(event) => setChoice(question.number, { other: event.target.value })} />
                )}
              </>
            )}
          </fieldset>
        );
      })}
      <label className="field">
        <span>{questions.length === 0 ? 'Your answer' : 'Note for the agent'}</span>
        <textarea rows={questions.length === 0 ? 3 : 2} placeholder={questions.length === 0 ? 'Say what the agent should do.' : 'Optional.'} value={note} onChange={(event) => setNote(event.target.value)} />
      </label>
      <div className="decision-actions">
        <button type="submit" className="button primary" disabled={!ready}>{questions.length > 1 ? 'Send answers' : 'Send answer'}</button>
        <span className="muted mono">{commandHint(gate, false)}</span>
      </div>
    </form>
  );
}

/** A merge gate: merge the PR from here when it is ready, or ask one more reviewer first. The next sweep then clears the gate. */
function MergeForm({ gate, ask, reviewers, onAnswer }: { gate: Gate; ask: string; reviewers: string[]; onAnswer: (decision: Decision, draft: Draft) => void }) {
  const pull = gate.pull;
  const ready = pull !== null && (pull.state === 'mergeable' || pull.state === 'approved');
  return (
    <div className="decision">
      <fieldset className="question">
        <legend>{ask}</legend>
        {pull === null && <p className="muted decision-help">No open pull request found for {gate.item}. Merge it on GitHub. The next sweep clears the gate.</p>}
        {pull !== null && !ready && pull.state === 'draft' && gate.quiz !== null && gate.quiz.result?.passed !== true && <p className="muted decision-help">PR #{pull.number} is a draft until you pass the quiz above; then it goes ready for review.</p>}
        {pull !== null && !ready && !(pull.state === 'draft' && gate.quiz !== null && gate.quiz.result?.passed !== true) && <p className="muted decision-help">PR #{pull.number} is not ready to merge: {pull.state}. The gate waits until it is.</p>}
        {pull !== null && ready && (
          <div className="decision-actions">
            <button type="button" className="button primary" onClick={() => onAnswer({ kind: 'merge', pr: pull.number, said: { verb: `Merged PR #${pull.number}`, message: '' } }, { choices: [], note: '', mode: null })}>Merge PR #{pull.number}</button>
            <span className="muted">Squash-merges and deletes the branch. The next sweep clears the gate and frees the worktree.</span>
          </div>
        )}
        {pull !== null && <div className="decision-actions"><AskReview pr={pull.number} reviewers={reviewers} /></div>}
      </fieldset>
    </div>
  );
}

/** A long text the gate is about, such as the plan or the issue, folded unless the gate asks you to judge it. */
function GateDocument({ title, file, text, open }: { title: string; file: string | null; text: string; open: boolean }) {
  return (
    <details className="gate-doc" open={open}>
      <summary>{title}{file !== null && <span className="muted mono"> {file}</span>}</summary>
      <Markdown text={text} />
    </details>
  );
}

/** The props of an answered card: the answer, the twins answered with it, and where to go next. */
type AnsweredCardProps = { entry: Answered; twins: Answered[]; snapshot: Snapshot; nextGate: Gate | null; onRetry: () => void };

/**
 * A gate just answered: what you decided, a log of what each action did (one clear line per twin
 * answered with it, each opening its own card), and the run going, live from the action records.
 */
function AnsweredCard({ entry, twins, snapshot, nextGate, onRetry }: AnsweredCardProps) {
  const { records } = useActionsView();
  const record = (step: Step | null): ActionRecord | undefined => (step?.state === 'started' ? records.find((candidate) => candidate.id === step.id) : undefined);
  const clear = entry.merge ? describeMerge(entry.clear, record(entry.clear), entry.gate) : describeClear(entry.clear, record(entry.clear), entry.gate, entry.back);
  const twinClears = twins.map((twin) => ({ item: twin.gate.item, line: describeClear(twin.clear, record(twin.clear), twin.gate, twin.back) }));
  const runRecord = record(entry.run);
  const run = entry.run === null ? null : describeRun(entry.run, runRecord, entry.gate, snapshot);
  const failed = clear.tone === 'failing';
  const going = entry.run?.state === 'started' && (runRecord === undefined || runRecord.state === 'running');
  const projectId = snapshot.project.id;
  const wt = worktreeName(entry.gate.worktree);
  const quoted = entry.said.message.trim() !== '' && !QUIET_MESSAGES.has(entry.said.message);
  return (
    <section className="decision-card answered" aria-label="Decision card">
      <DecisionHead gate={entry.gate} snapshot={snapshot} answered summary={null} />
      <div className="answered-body" aria-live="polite">
        <div className="answered-head">
          <span className={failed ? 'answered-mark failing' : 'answered-mark'} aria-hidden="true">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">{failed ? <path d="M6 6l12 12M18 6L6 18" /> : <path d="M5 12l5 5L20 7" />}</svg>
          </span>
          <span className="answered-title">{entry.said.verb} at {hourMinute(entry.at)}</span>
        </div>
        {quoted && <blockquote className="answer-sent"><Markdown text={entry.said.message} /></blockquote>}
        <div className="answer-log">
          <div className={`answer-line ${clear.tone}`}><span className="prompt">›</span> {clear.text}</div>
          {run !== null && run.text !== null && <div className={`answer-line ${run.tone}`}><span className="prompt">›</span> {run.text}</div>}
          {twinClears.map((twin) => (
            <a key={twin.item} className={`answer-line ${twin.line.tone}`} href={routeHash({ projectId, screen: 'gates', detail: twin.item })}><span className="prompt">›</span> {twin.line.text}</a>
          ))}
          {clear.detail !== null && <pre>{clear.detail}</pre>}
        </div>
        {going && (
          <div className="run-live">
            <div className="run-live-line"><Dot tone="running" /><span className="run-live-text">Run going{wt === null ? '' : ` in ${wt}`}</span><span className="muted">· watch it on Agents</span></div>
            <div className="run-stripes" />
          </div>
        )}
        <div className="decision-actions">
          {failed && <button type="button" className="button primary" onClick={onRetry}>Back to my answer</button>}
          {run !== null && !failed && <a className="button primary" href={routeHash({ projectId, screen: 'agents', detail: null })}>Watch the agent</a>}
          {nextGate !== null && <a className="button" href={routeHash({ projectId, screen: 'gates', detail: nextGate.item })}>Next gate</a>}
        </div>
      </div>
    </section>
  );
}

/** Messages the verb already says in full, so the card does not quote them back. */
const QUIET_MESSAGES = new Set(['Approved.', 'Signed off. It feels right.']);

/** The answer as the Answered list quotes it: the first line of the message, or the verb. */
function quoteOf(said: Said): string {
  if (said.message.trim() === '' || QUIET_MESSAGES.has(said.message)) return said.verb.toLowerCase();
  const first = said.message.split('\n').find((line) => line.trim() !== '') ?? '';
  return `“${first.trim()}”`;
}

type Line = { tone: 'running' | 'needs-you' | 'failing' | 'quiet'; text: string; detail: string | null };

function describeClear(step: Step, record: ActionRecord | undefined, gate: Gate, back: boolean): Line {
  const command = `gate.sh clear ${gate.item}${back ? ' --back' : ''}`;
  if (step.state === 'refused') return { tone: 'failing', text: `${command} · refused: ${step.message}`, detail: null };
  if (step.state !== 'started' || record === undefined || record.state === 'running') return { tone: 'needs-you', text: `${command} · posting your answer and clearing the gate…`, detail: null };
  if (record.state === 'done' && record.exitCode === 0) return { tone: 'running', text: `${command} · answer posted on the issue, gate cleared${back ? ', the step runs again' : ''}`, detail: null };
  return { tone: 'failing', text: `${command} · failed${record.exitCode === null ? '' : ` (exit ${record.exitCode})`}`, detail: record.outputTail.trim() || null };
}

function describeMerge(step: Step, record: ActionRecord | undefined, gate: Gate): Line {
  const command = `gh pr merge ${gate.pull?.number ?? ''}`.trim();
  if (step.state === 'refused') return { tone: 'failing', text: `${command} · refused: ${step.message}`, detail: null };
  if (step.state !== 'started' || record === undefined || record.state === 'running') return { tone: 'needs-you', text: `${command} · merging…`, detail: null };
  if (record.state === 'done' && record.exitCode === 0) return { tone: 'running', text: `${command} · merged; the next sweep clears the gate and frees the worktree`, detail: null };
  return { tone: 'failing', text: `${command} · failed${record.exitCode === null ? '' : ` (exit ${record.exitCode})`}`, detail: record.outputTail.trim() || null };
}

/** The run's log line, or no line while it waits for the clear: the log grows one line per action. */
function describeRun(step: Step, record: ActionRecord | undefined, gate: Gate, snapshot: Snapshot): { tone: Line['tone']; text: string | null } {
  const command = `next.sh ${gate.item}`;
  const where = worktreeName(gate.worktree);
  switch (step.state) {
    case 'waiting': return { tone: 'quiet', text: null };
    case 'skipped': return { tone: 'quiet', text: 'no run started · the gate did not clear' };
    case 'sending': return { tone: 'needs-you', text: `${command} · starting the run…` };
    case 'refused': return queueBusy(step.message) ? { tone: 'quiet', text: `${command} · ${queuedText(gate, snapshot)}` } : { tone: 'failing', text: `${command} · did not start: ${step.message}` };
    case 'started':
      if (record === undefined || record.state === 'running') return { tone: 'running', text: `${command} · run started${where === null ? '' : ` in ${where}`}` };
      if (record.state === 'done' && record.exitCode === 0) return { tone: 'quiet', text: `${command} · run ended` };
      return { tone: 'failing', text: `${command} · run failed${record.exitCode === null ? '' : ` (exit ${record.exitCode})`}` };
  }
}

/** A run refused because another run holds the queue: the console's own, or the scheduled next job. */
function queueBusy(message: string): boolean {
  return message.includes('job:next');
}

/** Where the answered item goes when the queue is busy: the next scheduled run, at its time when there is one. */
function queuedText(gate: Gate, snapshot: Snapshot): string {
  const next = snapshot.jobs.find((job) => job.name === 'next');
  if (next === undefined || !next.installed || next.next === '' || next.next === 'no schedule') {
    return 'another run holds the queue and no run is scheduled; start one from Jobs once it is free';
  }
  return `another run holds the queue; the next scheduled run picks up ${gate.item} (${next.next})`;
}

/** A local wall-clock time, HH:MM. */
function hourMinute(at: Date): string {
  return at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
}

/** When a gate was raised, as "30 Oct 09:24". */
function raisedAt(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return iso;
  return `${at.toLocaleDateString([], { day: 'numeric', month: 'short' })} ${hourMinute(at)}`;
}

function GatePull({ pull }: { pull: NonNullable<Gate['pull']> }) {
  const threads = pull.unresolvedThreads;
  return (
    <div className="gate-pull">
      <div className="gate-pull-line">
        <ExternalLink url={pull.url} className="mono">PR #{pull.number}</ExternalLink>
        <Chip tone={pullTone(pull.state)}>{pull.state}</Chip>
        <span className={threads > 0 ? 'tone-needs-you threads strong' : 'muted'}>{threads} unresolved review {threads === 1 ? 'thread' : 'threads'}</span>
      </div>
      {threads > 0 && <p className="muted">The comments job addresses threads; {threads === 1 ? 'this one is' : 'these are'} still open.</p>}
    </div>
  );
}
