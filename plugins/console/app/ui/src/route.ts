/** The screens of one project, and `settings`, which belongs to the daemon and lives at `#/settings`. */
export type Screen = 'overview' | 'gates' | 'worktrees' | 'agents' | 'pulls' | 'activity' | 'settings';

export const SCREENS: { screen: Screen; label: string }[] = [
  { screen: 'overview', label: 'Overview' },
  { screen: 'gates', label: 'Gates' },
  { screen: 'worktrees', label: 'Worktrees' },
  { screen: 'agents', label: 'Agents and jobs' },
  { screen: 'pulls', label: 'Pull requests' },
  { screen: 'activity', label: 'Activity' },
];

export const SETTINGS_HASH = '#/settings';

/** The title of a screen, Settings included. */
export function screenLabel(screen: Screen): string {
  return screen === 'settings' ? 'Settings' : SCREENS.find((entry) => entry.screen === screen)?.label ?? screen;
}

/** Where the page is: `#/<project>/<screen>/<detail>`, every part optional, or `#/settings`. */
export type Route = { projectId: string | null; screen: Screen; detail: string | null };

export function parseRoute(hash: string): Route {
  const [projectPart, screenPart, detailPart] = hash.replace(/^#\/?/, '').split('/').map(decodeSegment);
  if (projectPart === 'settings' && screenPart === undefined) return { projectId: null, screen: 'settings', detail: null };
  const known = SCREENS.find((entry) => entry.screen === screenPart);
  return {
    projectId: projectPart === undefined || projectPart === '' ? null : projectPart,
    screen: known?.screen ?? 'overview',
    detail: detailPart === undefined || detailPart === '' ? null : detailPart,
  };
}

export function routeHash(route: Route): string {
  if (route.screen === 'settings') return SETTINGS_HASH;
  const parts = [route.projectId ?? '', route.screen];
  if (route.detail !== null) parts.push(route.detail);
  return `#/${parts.map(encodeURIComponent).join('/')}`;
}

function decodeSegment(segment: string): string {
  try { return decodeURIComponent(segment); } catch { return segment; }
}
