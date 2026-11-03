import type { Lesson, RetroRun, Snapshot } from '../../daemon/src/snapshot.ts';

/** The lessons of one rule within a kind; `rule` is null for the lessons that name none. */
export type RuleGroup = { rule: string | null; lessons: Lesson[] };
/** The lessons of one kind, by rule. */
export type KindGroup = { kind: string; count: number; rules: RuleGroup[] };

/**
 * The lessons after the last retro, oldest first: the newest `counts.lessonsSinceRetro`, since the
 * lessons are in file order and the daemon counts the ones past the last retro's line.
 */
export function lessonsSinceRetro(snapshot: Pick<Snapshot, 'lessons' | 'counts'>): Lesson[] {
  const since = snapshot.counts.lessonsSinceRetro;
  return since <= 0 ? [] : snapshot.lessons.slice(-since);
}

/** The retro the count is measured from: the newest run with a log line, else the newest report; null before any. */
export function lastRetro(retros: readonly RetroRun[]): RetroRun | null {
  return retros.find((run) => run.at !== null) ?? retros[0] ?? null;
}

/**
 * The lessons by kind, then by rule, so a theme stands out: the kinds and the rules with the most
 * lessons first, then by name, the lessons with no rule last within their kind.
 */
export function lessonGroups(lessons: readonly Lesson[]): KindGroup[] {
  const kinds = new Map<string, Map<string | null, Lesson[]>>();
  for (const lesson of lessons) {
    const rules = kinds.get(lesson.kind) ?? new Map<string | null, Lesson[]>();
    rules.set(lesson.rule, [...(rules.get(lesson.rule) ?? []), lesson]);
    kinds.set(lesson.kind, rules);
  }
  const groups = [...kinds].map(([kind, rules]) => {
    const ruleGroups = [...rules].map(([rule, members]) => ({ rule, lessons: members })).sort(byRule);
    return { kind, count: ruleGroups.reduce((sum, group) => sum + group.lessons.length, 0), rules: ruleGroups };
  });
  return groups.sort((left, right) => right.count - left.count || left.kind.localeCompare(right.kind));
}

function byRule(left: RuleGroup, right: RuleGroup): number {
  if ((left.rule === null) !== (right.rule === null)) return left.rule === null ? 1 : -1;
  return right.lessons.length - left.lessons.length || (left.rule ?? '').localeCompare(right.rule ?? '');
}

/** "1 lesson", "3 lessons". */
export function lessonCount(count: number): string {
  return `${count} ${count === 1 ? 'lesson' : 'lessons'}`;
}

/** The Overview's line: how many lessons the next retro will read, or that none waits. */
export function lessonsSentence(snapshot: Pick<Snapshot, 'counts' | 'retros'>): string {
  const since = snapshot.counts.lessonsSinceRetro;
  if (lastRetro(snapshot.retros) === null) return since === 0 ? 'No lesson recorded yet.' : `${lessonCount(since)} recorded, and no retro has run yet.`;
  return since === 0 ? 'No lesson since the last retro.' : `${lessonCount(since)} since the last retro.`;
}
