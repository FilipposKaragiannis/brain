import assert from 'node:assert/strict';
import { test } from 'node:test';
import { filterEvents, parseEvents } from '../src/events.ts';

const LOG = '2026-10-24T17:47:00Z\tgh#213\tambiguity\tcleared: go with option b3\n2026-10-24T17:58:00Z\t-\thealth\tfast-forwarded wt-2\nbroken line\n2026-10-24T18:14:00Z\tgh#213\tcomments\ta\tb\n';

test('Events_NewestFirstAndMalformedSkipped', () => {
  const events = parseEvents(LOG, 10);
  assert.equal(events.length, 3, 'because the broken line has no four fields');
  assert.equal(events[0]?.at, '2026-10-24T18:14:00Z', 'because the UI shows the latest event on top');
});

test('DashItem_IsNull', () => {
  assert.equal(parseEvents(LOG, 10)[1]?.item, null, 'because a dash marks a project-wide event');
});

test('MessageWithTabs_KeptWhole', () => {
  assert.equal(parseEvents(LOG, 10)[0]?.message, 'a\tb', 'because the message is everything after the third tab');
});

test('Keep_LimitsToNewest', () => {
  assert.deepEqual(parseEvents(LOG, 1).map((event) => event.kind), ['comments'], 'because the limit drops the oldest');
});

test('FilterEvents_OneItemNewestFirstWithinLimit', () => {
  const filtered = filterEvents(parseEvents(LOG, 10), 'gh#213', 1);
  assert.deepEqual([filtered.events.map((event) => event.kind), filtered.total], [['comments'], 2], 'because the activity of one item is its own events, newest first, and the total says how many more there are');
});

test('FilterEvents_NoItem_AllEvents', () => {
  assert.equal(filterEvents(parseEvents(LOG, 10), null, 10).events.length, 3, 'because without an item every kept event is activity');
});
