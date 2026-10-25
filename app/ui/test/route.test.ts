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

test('ActivityHashWithAnItem_NarrowsToThatItem', () => {
  expect(parseRoute('#/foosbrawl/activity/gh%23515'), 'because the activity screen links straight to one item\'s events').toEqual({ projectId: 'foosbrawl', screen: 'activity', detail: 'gh#515' });
});

test('SettingsHash_IsTheSettingsScreen', () => {
  expect(parseRoute('#/settings'), 'because the settings belong to the daemon, not to one project').toEqual({ projectId: null, screen: 'settings', detail: null });
});

test('SettingsRoute_WritesTheSettingsHash', () => {
  expect(routeHash({ projectId: 'foosbrawl', screen: 'settings', detail: null }), 'because every Settings link lands on the one page whatever project was open').toBe('#/settings');
});
