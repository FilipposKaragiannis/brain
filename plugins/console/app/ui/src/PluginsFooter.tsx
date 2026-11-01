import type { InstalledPlugin, ProjectInfo } from '../../daemon/src/snapshot.ts';

/** The plugin the flow scripts run; it leads the table. */
const FLOW = 'flow';

export const PROVIDERS_DIFFER = 'Claude Code and Codex differ';
export const NO_PLUGINS = 'No plugins found in ~/.claude or ~/.codex.';
/** What a cell shows when that provider lacks the plugin. */
export const MISSING = '—';

/** How the flow plugin the scripts use was found. */
export function pluginTitle(project: ProjectInfo): string {
  if (project.pluginSource === null || project.pluginRoot === null) return 'No flow plugin found for this project';
  if (project.pluginSource === 'FLOW_PLUGIN') return `Set by FLOW_PLUGIN when the daemon started: ${project.pluginRoot}`;
  return `The installed plugin, as .flow/plugin.sh finds it: ${project.pluginRoot}`;
}

/** Flow first, then the rest by name. */
export function pluginOrder(plugins: InstalledPlugin[]): InstalledPlugin[] {
  return [...plugins].sort((left, right) => Number(right.name === FLOW) - Number(left.name === FLOW) || left.name.localeCompare(right.name));
}

/**
 * The page's footer: every plugin of flow's marketplace, a row each, with the version Claude Code
 * and Codex have, a mismatch in the needs-you colour, and one line on the flow the scripts use.
 */
export function PluginsFooter({ project }: { project: ProjectInfo }) {
  const plugins = pluginOrder(project.plugins);
  const marketplaces = [...new Set(plugins.map((plugin) => plugin.marketplace))].join(', ');
  return (
    <footer className="plugins-footer" aria-label="Installed plugins">
      {plugins.length === 0 ? <p className="plugins-empty">{NO_PLUGINS}</p> : (
        <div className="plugins-scroll">
          <table className="plugins-table">
            <caption>Plugins from {marketplaces}</caption>
            <thead><tr><th scope="col">Plugin</th><th scope="col">Claude Code</th><th scope="col">Codex</th></tr></thead>
            <tbody>
              {plugins.map((plugin) => <PluginRow key={`${plugin.marketplace}/${plugin.name}`} plugin={plugin} />)}
            </tbody>
          </table>
        </div>
      )}
      <p className="plugins-flow" title={pluginTitle(project)}>{flowScriptsLine(project)}</p>
    </footer>
  );
}

/** Which flow the scripts run and where it came from, in pluginTitle's words. */
export function flowScriptsLine(project: ProjectInfo): string {
  if (project.pluginSource === null || project.pluginRoot === null) return 'Flow scripts: no flow plugin found for this project.';
  return `Flow scripts use ${project.pluginVersion ?? 'an unknown version'} · ${pluginTitle(project)}`;
}

function PluginRow({ plugin }: { plugin: InstalledPlugin }) {
  const differ = plugin.claude !== null && plugin.codex !== null && plugin.claude !== plugin.codex;
  return (
    <tr>
      <th scope="row">{plugin.name}</th>
      <VersionCell version={plugin.claude} provider="Claude Code" differ={differ} />
      <VersionCell version={plugin.codex} provider="Codex" differ={differ} />
    </tr>
  );
}

function VersionCell({ version, provider, differ }: { version: string | null; provider: string; differ: boolean }) {
  if (version === null) return <td className="plugin-missing" title={`Not installed for ${provider}`}>{MISSING}</td>;
  return <td className={differ ? 'plugin-version plugin-differs' : 'plugin-version'} title={differ ? PROVIDERS_DIFFER : undefined}>{version}</td>;
}
