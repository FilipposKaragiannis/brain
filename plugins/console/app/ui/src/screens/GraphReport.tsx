import { useEffect, useState } from 'react';
import type { Snapshot } from '../../../daemon/src/snapshot.ts';
import { projectPath, unreachableMessage } from '../api.ts';
import { useServices } from '../console.tsx';
import { Markdown } from '../Markdown.tsx';
import { Empty, Module } from '../ui.tsx';
import { HTTP_OK } from '../useProject.ts';

type GraphReportRead =
  | { kind: 'reading' }
  | { kind: 'read'; days: number; markdown: string }
  | { kind: 'failed'; message: string };

/**
 * The flow's graph report of the project, asked from the daemon when the screen opens and again
 * each time `asked` changes. The daemon runs the flow script on every ask and keeps no copy.
 */
function useGraphReport(projectId: string, asked: number): GraphReportRead {
  const { api } = useServices();
  const [read, setRead] = useState<GraphReportRead>({ kind: 'reading' });
  useEffect(() => {
    let cancelled = false;
    setRead({ kind: 'reading' });
    void api.request(projectPath(projectId, '/graph-report'), 'GET', null).then((response) => {
      if (cancelled) return;
      const body = response.body as { days?: unknown; markdown?: unknown; error?: unknown } | null;
      if (response.status === HTTP_OK && typeof body?.markdown === 'string') {
        setRead({ kind: 'read', days: Number(body.days ?? 0), markdown: body.markdown });
        return;
      }
      setRead({ kind: 'failed', message: typeof body?.error === 'string' ? body.error : unreachableMessage(response.status) });
    });
    return () => { cancelled = true; };
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
        {read.kind === 'read' && <Markdown text={read.markdown} />}
      </Module>
    </div>
  );
}
