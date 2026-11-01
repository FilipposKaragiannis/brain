import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SELF_CHECK_MS, SelfCheck } from '../src/selfCheck.ts';
import { fakeScheduler } from './fakeSpawner.ts';

/** A self check of a daemon running `running`, over a cache whose newest version the test sets. */
function selfCheck(running: string, cached: string | null) {
  const cache = { newest: cached };
  const timers = fakeScheduler();
  const check = new SelfCheck({ running, newestCached: () => cache.newest, configStamp: () => null, onConfigChange: () => {}, scheduler: timers.scheduler });
  return { check, cache, timers };
}

test('NewerConsole_CacheHoldsANewerVersion_NamesBoth', () => {
  const { check } = selfCheck('0.9.2', '0.10.0');
  check.start();
  assert.deepEqual(check.newerConsole(), { running: '0.9.2', cached: '0.10.0' }, 'because 0.10.0 is newer than 0.9.2 by number, and the notice names both');
  check.stop();
});

test('NewerConsole_NothingNewerCached_None', () => {
  for (const [running, cached] of [['0.10.0', '0.10.0'], ['0.10.0', '0.9.2'], ['0.10.0', null]] as const) {
    const { check } = selfCheck(running, cached);
    check.start();
    assert.equal(check.newerConsole(), null, `because a daemon on ${running} with ${cached ?? 'nothing'} in the cache runs the newest console`);
    check.stop();
  }
});

test('NewerConsole_InstalledWhileRunning_SeenOnTheNextMinute', () => {
  const { check, cache, timers } = selfCheck('0.9.2', '0.9.2');
  check.start();
  cache.newest = '0.10.0';
  timers.fire(SELF_CHECK_MS);
  assert.deepEqual(check.newerConsole(), { running: '0.9.2', cached: '0.10.0' }, 'because the daemon looks at the cache again every minute');
  check.stop();
});
