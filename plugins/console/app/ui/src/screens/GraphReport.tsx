import { useEffect, useState } from 'react';
import type { StepDay } from '../../../daemon/src/collectors/graphReport.ts';
import type { Snapshot } from '../../../daemon/src/snapshot.ts';
import { projectPath, unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { Markdown } from '../Markdown.tsx';
import { StepTrends } from '../StepTrends.tsx';
import { Empty, Module } from '../ui.tsx';
import { HTTP_OK } from '../useProject.ts';

/** What the report's numbers mean, as markdown: the page's own words, shown above the flow script's report. */
function howToRead(days: number): string {
  return [
    `A **step run** is one agent session on one step of one item. The report covers the last ${days} days and compares them with the ${days} days before.`,
    '',
    '- **runs**: how many times the step ran.',
    '- **median**: the typical time of one run. Half of the runs were shorter.',
    '- **nine in ten within**: nine runs out of ten finished within this time. It shows the slow runs.',
    '- **failed**: runs that ended with an error.',
    '- **cost**: what the model spent on the step.',
    '- **runs per item**: how often the step ran for one item. 1.0 means once. Above 2, items went back and forth.',
    '',
    'A step is listed as **slower** when its median grew by half or more. The last table names the five items that used the most agent time.',
    '',
    'Watch for a step listed as slower, runs per item above 2, and a failed count that grows.',
    '',
    'The charts on top show the typical time of one run for each day. A line that climbs is a step getting slower.',
  ].join('\n');
}

type GraphReportRead =
  | { kind: 'reading' }
  | { kind: 'read'; days: number; markdown: string; daily: StepDay[] }
  | { kind: 'failed'; message: string };

/**
 * The flow's graph report of the project, asked from the daemon when the screen opens and again
 * each time `asked` changes. The daemon runs the flow script on every ask and keeps no copy, so a
 * screen that closes cancels its request and the daemon ends the script.
 */
function useGraphReport(projectId: string, asked: number): GraphReportRead {
  const { api } = useServices();
  const [read, setRead] = useState<GraphReportRead>({ kind: 'reading' });
  useEffect(() => {
    const leaving = new AbortController();
    setRead({ kind: 'reading' });
    void api.get(projectPath(projectId, '/graph-report'), leaving.signal).then((response) => {
      if (leaving.signal.aborted) return;
      const body = response.body as { days?: unknown; markdown?: unknown; daily?: unknown; error?: unknown } | null;
      if (response.status === HTTP_OK && typeof body?.markdown === 'string') {
        setRead({ kind: 'read', days: Number(body.days ?? 0), markdown: body.markdown, daily: Array.isArray(body.daily) ? (body.daily as StepDay[]) : [] });
        return;
      }
      setRead({ kind: 'failed', message: typeof body?.error === 'string' ? body.error : unreachableMessage(response.status) });
    });
    return () => { leaving.abort(); };
  }, [api, projectId, asked]);
  return read;
}

/**
 * What each flow step cost in the last days: its runs, its median time, its failed runs, its cost
 * and its runs per item, the steps that got slower against the days before, and the items that
 * took the most step time. The flow script's own report, shown as it printed it.
 */
export function GraphReport({ snapshot }: { snapshot: Snapshot }) {
  const [asked, setAsked] = useState(0);
  const read = useGraphReport(snapshot.project.id, asked);
  const period = read.kind === 'read' ? `the last ${read.days} days against the ${read.days} before` : 'read from the run log when you open this page';
  return (
    <div className="screen">
      <Module
        className="graph-report"
        title="What each step cost"
        aside={<button type="button" className="button" disabled={read.kind === 'reading'} onClick={() => setAsked((count) => count + 1)}>Read again</button>}
        footer={<span className="muted">{period}</span>}
      >
        {read.kind === 'reading' && <Empty>Reading the run log…</Empty>}
        {read.kind === 'failed' && <Empty>No graph report: {read.message}.</Empty>}
        {read.kind === 'read' && (
          <>
            <StepTrends daily={read.daily} />
            <details className="gate-doc">
              <summary>How to read this</summary>
              <Markdown text={howToRead(read.days)} />
            </details>
            <Markdown text={read.markdown} />
          </>
        )}
      </Module>
    </div>
  );
}
