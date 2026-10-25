import { createContext, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';

export const TICK_MS = 1000;
const MILLISECONDS_PER_SECOND = 1000;
const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86400;

export type Clock = () => number;

const NowContext = createContext<number | null>(null);

/** The page's one timer: every live counter reads this shared "now", so one tick re-renders them all. */
export function ClockProvider({ clock, children }: { clock: Clock; children: ReactNode }) {
  const [now, setNow] = useState(clock);
  useEffect(() => {
    const timer = setInterval(() => setNow(clock()), TICK_MS);
    return () => clearInterval(timer);
  }, [clock]);
  return <NowContext.Provider value={now}>{children}</NowContext.Provider>;
}

export function useNow(): number {
  const now = useContext(NowContext);
  if (now === null) throw new Error('useNow needs a ClockProvider above it');
  return now;
}

/** An age read at `takenAt`, carried forward to `now`. */
export function liveSeconds(ageSeconds: number | null, takenAt: string, now: number): number | null {
  if (ageSeconds === null) return null;
  const sinceSnapshot = Math.floor((now - Date.parse(takenAt)) / MILLISECONDS_PER_SECOND);
  return Math.max(0, ageSeconds + Math.max(0, sinceSnapshot));
}

export function useLiveSeconds(ageSeconds: number | null, takenAt: string): number | null {
  return liveSeconds(ageSeconds, takenAt, useNow());
}

export function formatDuration(seconds: number | null): string {
  if (seconds === null) return '—';
  const days = Math.floor(seconds / SECONDS_PER_DAY);
  const hours = Math.floor((seconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR);
  const minutes = Math.floor((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE);
  const rest = seconds % SECONDS_PER_MINUTE;
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${pad(minutes)}m`;
  if (minutes > 0) return `${minutes}m ${pad(rest)}s`;
  return `${rest}s`;
}

function pad(value: number): string {
  return String(value).padStart(2, '0');
}

/** A live age counter. */
export function Age({ seconds, takenAt }: { seconds: number | null; takenAt: string }) {
  const live = useLiveSeconds(seconds, takenAt);
  return <span className="age">{formatDuration(live)}</span>;
}

/** A live counter for a moment in the past, such as a source's last read. */
export function Since({ at }: { at: string | null }) {
  const now = useNow();
  if (at === null) return <span className="age">never</span>;
  const seconds = Math.max(0, Math.floor((now - Date.parse(at)) / MILLISECONDS_PER_SECOND));
  return <span className="age">{formatDuration(seconds)} ago</span>;
}

export function clockTime(iso: string): string {
  const moment = new Date(iso);
  return `${pad(moment.getHours())}:${pad(moment.getMinutes())}`;
}
