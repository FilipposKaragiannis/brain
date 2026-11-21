import { useState } from 'react';
import type { StepDay } from '../../daemon/src/collectors/graphReport.ts';
import { formatDuration } from './clock.tsx';
import { daysCharted, stepTrends } from './stepTrends.ts';
import type { StepTrend } from './stepTrends.ts';

/** The plot of one panel, in the units of its viewBox: the frame, and the room around the line. */
const PLOT = { width: 280, height: 84, left: 4, right: 8, top: 14, bottom: 6 };
const DOT_RADIUS = 4;
const SCALE_LABEL_RISE = 4;
const MONTH_AND_DAY_START = 5;

function count(runs: number, noun: string): string {
  return `${runs} ${noun}${runs === 1 ? '' : 's'}`;
}

/** What a step did on one day, in words: its typical time, its runs and the failed ones. */
function dayInWords(line: StepDay | undefined): string {
  if (line === undefined) return 'no run';
  const failed = line.failed === 0 ? '' : `, ${line.failed} failed`;
  return `${formatDuration(line.median)}, ${count(line.runs, 'run')}${failed}`;
}

/**
 * One step's typical run time, day by day: a line over the days the charts share, the last day's
 * value as the figure, and a readout of the day the pointer is on. The scale is the step's own:
 * the top line is its slowest day.
 */
function TrendPanel({ trend, days, activeDay, onActiveDay }: { trend: StepTrend; days: string[]; activeDay: string | null; onActiveDay: (day: string | null) => void }) {
  const slowest = Math.max(...trend.days.map((line) => line.median), 1);
  const span = Math.max(days.length - 1, 1);
  const across = (day: string): number => PLOT.left + (days.indexOf(day) / span) * (PLOT.width - PLOT.left - PLOT.right);
  const up = (seconds: number): number => PLOT.top + (1 - seconds / slowest) * (PLOT.height - PLOT.top - PLOT.bottom);
  const line = trend.days.map((point, index) => `${index === 0 ? 'M' : 'L'}${across(point.day).toFixed(1)} ${up(point.median).toFixed(1)}`).join(' ');
  const latest = trend.days.at(-1)!;
  const active = activeDay === null ? undefined : trend.days.find((point) => point.day === activeDay);
  const column = (PLOT.width - PLOT.left - PLOT.right) / span;
  return (
    <section className="step-trend" aria-label={`${trend.step}: typical run time by day`}>
      <header className="step-trend-head">
        <h3>{trend.step}</h3>
        <span className="step-trend-figure">{formatDuration(latest.median)}</span>
      </header>
      <p className="step-trend-readout">{activeDay === null ? `latest day, ${latest.day}` : `${activeDay}: ${dayInWords(active)}`}</p>
      <svg viewBox={`0 0 ${PLOT.width} ${PLOT.height}`} role="img" aria-label={`${trend.step} took ${formatDuration(trend.days[0]!.median)} on ${trend.days[0]!.day} and ${formatDuration(latest.median)} on ${latest.day}`} onPointerLeave={() => onActiveDay(null)}>
        <line className="step-trend-grid" x1={PLOT.left} x2={PLOT.width - PLOT.right} y1={up(slowest)} y2={up(slowest)} />
        <line className="step-trend-grid" x1={PLOT.left} x2={PLOT.width - PLOT.right} y1={up(0)} y2={up(0)} />
        <text className="step-trend-scale" x={PLOT.left} y={up(slowest) - SCALE_LABEL_RISE}>{formatDuration(slowest)}</text>
        {activeDay !== null && <line className="step-trend-crosshair" x1={across(activeDay)} x2={across(activeDay)} y1={PLOT.top} y2={up(0)} />}
        <path className="step-trend-line" d={line} />
        <circle className="step-trend-dot" cx={across(latest.day)} cy={up(latest.median)} r={DOT_RADIUS} />
        {active !== undefined && <circle className="step-trend-dot" cx={across(active.day)} cy={up(active.median)} r={DOT_RADIUS} />}
        {days.map((day) => (
          <rect key={day} className="step-trend-hit" data-day={day} x={across(day) - column / 2} y={0} width={column} height={PLOT.height} onPointerEnter={() => onActiveDay(day)} />
        ))}
      </svg>
      <p className="step-trend-days"><span>{days[0]!.slice(MONTH_AND_DAY_START)}</span><span>{days.at(-1)!.slice(MONTH_AND_DAY_START)}</span></p>
    </section>
  );
}

/** The same numbers as the charts, as a table: every day, newest first, with each step's typical time and runs. */
function DailyNumbers({ trends, days }: { trends: StepTrend[]; days: string[] }) {
  return (
    <details className="gate-doc">
      <summary>Daily numbers</summary>
      <div className="scroll">
        <table className="table">
          <thead><tr><th>day</th>{trends.map((trend) => <th key={trend.step}>{trend.step}</th>)}</tr></thead>
          <tbody>
            {[...days].reverse().map((day) => (
              <tr key={day}>
                <td className="mono">{day}</td>
                {trends.map((trend) => <td key={trend.step}>{dayInWords(trend.days.find((line) => line.day === day))}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

/**
 * How long one run of each step took, day by day, for the steps that used the most time: one
 * small chart per step on a shared time axis, so a step that got slower shows as a line that
 * climbs. Pointing at a day reads that day out in every chart. Nothing is drawn without a day.
 */
export function StepTrends({ daily }: { daily: StepDay[] }) {
  const [activeDay, setActiveDay] = useState<string | null>(null);
  const trends = stepTrends(daily);
  const days = daysCharted(trends);
  if (trends.length === 0) return null;
  return (
    <section className="step-trends" aria-label="Steps over time">
      <h3 className="step-trends-title">Typical time of one run, day by day</h3>
      <p className="muted step-trends-note">One chart per step, for the {trends.length === 1 ? 'step' : `${trends.length} steps`} that used the most time. Each has its own scale: the top line is that step's slowest day.</p>
      <div className="step-trends-grid">
        {trends.map((trend) => <TrendPanel key={trend.step} trend={trend} days={days} activeDay={activeDay} onActiveDay={setActiveDay} />)}
      </div>
      <DailyNumbers trends={trends} days={days} />
    </section>
  );
}
