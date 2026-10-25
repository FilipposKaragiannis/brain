export type Screen = 'overview' | 'gates' | 'worktrees' | 'agents' | 'pulls' | 'activity';

export const SCREENS: { screen: Screen; label: string }[] = [
  { screen: 'overview', label: 'Overview' },
  { screen: 'gates', label: 'Gates' },
  { screen: 'worktrees', label: 'Worktrees' },
  { screen: 'agents', label: 'Agents and jobs' },
  { screen: 'pulls', label: 'Pull requests' },
  { screen: 'activity', label: 'Activity' },
];

/** Where the page is: `#/<project>/<screen>/<detail>`, every part optional. */
export type Route = { projectId: string | null; screen: Screen; detail: string | null };

export function parseRoute(hash: string): Route {
  const [projectPart, screenPart, detailPart] = hash.replace(/^#\/?/, '').split('/').map(decodeSegment);
  const known = SCREENS.find((entry) => entry.screen === screenPart);
  return {
    projectId: projectPart === undefined || projectPart === '' ? null : projectPart,
    screen: known?.screen ?? 'overview',
    detail: detailPart === undefined || detailPart === '' ? null : detailPart,
  };
}

export function routeHash(route: Route): string {
  const parts = [route.projectId ?? '', route.screen];
  if (route.detail !== null) parts.push(route.detail);
  return `#/${parts.map(encodeURIComponent).join('/')}`;
}

function decodeSegment(segment: string): string {
  try { return decodeURIComponent(segment); } catch { return segment; }
}
