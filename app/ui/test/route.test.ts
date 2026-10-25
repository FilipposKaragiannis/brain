import { expect, test } from 'vitest';
import { parseRoute, routeHash } from '../src/route.ts';

test('GateHash_OpensThatGatesCard', () => {
  expect(parseRoute('#/foosbrawl/gates/gh%23322'), 'because a needs-you row links straight to its decision card').toEqual({ projectId: 'foosbrawl', screen: 'gates', detail: 'gh#322' });
});

test('UnknownScreen_FallsBackToOverview', () => {
  expect(parseRoute('#/foosbrawl/nowhere').screen, 'because a stale bookmark should still land somewhere useful').toBe('overview');
});

test('RouteToHashAndBack_RoundTrips', () => {
  const route = { projectId: 'my project', screen: 'gates' as const, detail: 'gh#7' };
  expect(parseRoute(routeHash(route)), 'because links the page writes must parse back to the same place').toEqual(route);
});
