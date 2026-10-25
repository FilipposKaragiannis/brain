import { act, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { Age, ClockProvider, formatDuration, liveSeconds, TICK_MS } from '../src/clock.tsx';

const TAKEN_AT = '2026-10-24T18:16:04Z';
const TAKEN_AT_MS = Date.parse(TAKEN_AT);
const AGE_AT_SNAPSHOT = 65;
const SECONDS_SINCE_SNAPSHOT = 7;
const MILLISECONDS_PER_SECOND = 1000;

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); });

test('AgeAtSnapshot_KeepsCountingOnTheReadersClock', () => {
  const seconds = liveSeconds(AGE_AT_SNAPSHOT, TAKEN_AT, TAKEN_AT_MS + SECONDS_SINCE_SNAPSHOT * MILLISECONDS_PER_SECOND);
  expect(seconds, 'because an age is seconds at takenAt plus the time since').toBe(AGE_AT_SNAPSHOT + SECONDS_SINCE_SNAPSHOT);
});

test('ReaderClockBehindSnapshot_NeverCountsBackwards', () => {
  const seconds = liveSeconds(AGE_AT_SNAPSHOT, TAKEN_AT, TAKEN_AT_MS - SECONDS_SINCE_SNAPSHOT * MILLISECONDS_PER_SECOND);
  expect(seconds, 'because clock skew between the daemon and the browser must not make an age shrink').toBe(AGE_AT_SNAPSHOT);
});

test('UnknownAge_StaysUnknown', () => {
  expect(liveSeconds(null, TAKEN_AT, TAKEN_AT_MS), 'because a missing age is not zero').toBeNull();
});

test('DurationAcrossUnits_ShowsTheTwoLargest', () => {
  const twoDaysOneHour = 2 * 86400 + 3600 + 59;
  expect(formatDuration(twoDaysOneHour), 'because a gate two days old reads in days and hours').toBe('2d 1h');
});

test('AgeCounter_TicksOnceASecond', () => {
  let now = TAKEN_AT_MS;
  render(<ClockProvider clock={() => now}><Age seconds={AGE_AT_SNAPSHOT} takenAt={TAKEN_AT} /></ClockProvider>);
  expect(screen.getByText('1m 05s'), 'because the counter starts at the snapshot age').toBeTruthy();
  now += SECONDS_SINCE_SNAPSHOT * MILLISECONDS_PER_SECOND;
  act(() => { vi.advanceTimersByTime(TICK_MS); });
  expect(screen.getByText('1m 12s'), 'because the shared clock tick re-reads now and the age moves with it').toBeTruthy();
});
