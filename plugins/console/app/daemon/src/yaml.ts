/**
 * The flat YAML subset the flow config uses, the same one `yaml_get` in lib/flow.sh reads:
 * two-space indentation, `key: value`, nested maps, block lists and inline lists. Quotes are
 * stripped. Anchors, multi-line scalars and flow maps are not supported on purpose.
 */
export type YamlValue = string | YamlValue[] | YamlMap;
export type YamlMap = { [key: string]: YamlValue };

const INDENT_WIDTH = 2;

type Line = { depth: number; text: string };

function stripQuotes(raw: string): string {
  const trimmed = raw.trim();
  const quoted = (trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"));
  return quoted && trimmed.length >= 2 ? trimmed.slice(1, -1) : trimmed;
}

function withoutComment(text: string): string {
  const hash = text.indexOf(' #');
  return hash < 0 ? text : text.slice(0, hash);
}

function inlineList(text: string): string[] {
  const inner = text.trim().slice(1, -1);
  return inner.split(',').map(stripQuotes).filter((part) => part.length > 0);
}

function meaningfulLines(source: string): Line[] {
  const lines: Line[] = [];
  for (const raw of source.split('\n')) {
    const line = withoutComment(raw.replace(/\r$/, ''));
    if (line.trim().length === 0 || line.trim().startsWith('#')) continue;
    const leading = line.length - line.trimStart().length;
    lines.push({ depth: Math.floor(leading / INDENT_WIDTH), text: line.trim() });
  }
  return lines;
}

function parseBlock(lines: Line[], start: number, depth: number): { value: YamlValue; next: number } {
  const first = lines[start];
  if (first === undefined || first.depth < depth) return { value: {}, next: start };
  if (first.text.startsWith('- ')) return parseList(lines, start, depth);
  return parseMap(lines, start, depth);
}

function parseList(lines: Line[], start: number, depth: number): { value: YamlValue[]; next: number } {
  const items: YamlValue[] = [];
  let index = start;
  while (index < lines.length) {
    const line = lines[index];
    if (line === undefined || line.depth !== depth || !line.text.startsWith('- ')) break;
    items.push(stripQuotes(line.text.slice(2)));
    index += 1;
  }
  return { value: items, next: index };
}

function parseMap(lines: Line[], start: number, depth: number): { value: YamlMap; next: number } {
  const map: YamlMap = {};
  let index = start;
  while (index < lines.length) {
    const line = lines[index];
    if (line === undefined || line.depth < depth) break;
    if (line.depth > depth) { index += 1; continue; }
    const colon = line.text.indexOf(':');
    if (colon < 0) { index += 1; continue; }
    const key = line.text.slice(0, colon).trim();
    const rest = line.text.slice(colon + 1).trim();
    index += 1;
    if (rest.length === 0) {
      const block = parseBlock(lines, index, depth + 1);
      map[key] = block.value;
      index = block.next;
      continue;
    }
    map[key] = rest.startsWith('[') && rest.endsWith(']') ? inlineList(rest) : stripQuotes(rest);
  }
  return { value: map, next: index };
}

export function parseYaml(source: string): YamlMap {
  return parseMap(meaningfulLines(source), 0, 0).value;
}

/** A dotted lookup that returns the string at the path, or null when absent or not a string. */
export function yamlString(map: YamlMap, path: string): string | null {
  const value = yamlAt(map, path);
  return typeof value === 'string' ? value : null;
}

/** A dotted lookup that returns the list at the path; a scalar becomes a one-item list, absence an empty one. */
export function yamlList(map: YamlMap, path: string): string[] {
  const value = yamlAt(map, path);
  if (Array.isArray(value)) return value.filter((entry): entry is string => typeof entry === 'string');
  if (typeof value === 'string') return value.length > 0 ? [value] : [];
  return [];
}

export function yamlMap(map: YamlMap, path: string): YamlMap {
  const value = yamlAt(map, path);
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function yamlAt(map: YamlMap, path: string): YamlValue | null {
  let current: YamlValue = map;
  for (const key of path.split('.')) {
    if (typeof current !== 'object' || Array.isArray(current)) return null;
    const next: YamlValue | undefined = current[key];
    if (next === undefined) return null;
    current = next;
  }
  return current;
}
