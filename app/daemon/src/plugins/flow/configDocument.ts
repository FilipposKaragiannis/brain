/**
 * `.flow/config.yaml` as lines, so a change rewrites only the value it touches and every comment,
 * blank line and key keeps its place. The format is the flat one the file's header names and
 * lib/flow.sh reads: two-space indentation, `key: value`, nested maps, lists as `- item` or
 * `[a, b]`. Anything else (tabs, anchors, block scalars, flow maps, a list of maps) is refused with
 * the line, never guessed at.
 */
import { parseYaml } from '../../yaml.ts';
import type { YamlMap, YamlValue } from '../../yaml.ts';
import type { FieldValue } from './schema.ts';

const INDENT = 2;
const KEY = /^([A-Za-z0-9_][A-Za-z0-9_.-]*):(.*)$/;
/** What a value may not start with: an anchor, an alias, a tag, a block scalar, a flow map. */
const UNSUPPORTED_START: Record<string, string> = { '&': 'an anchor', '*': 'an alias', '!': 'a tag', '|': 'a multi-line string', '>': 'a multi-line string', '{': 'a flow map', '%': 'a directive', '@': 'a reserved character', '`': 'a reserved character' };

type Common = { index: number; indent: number; raw: string };
export type KeyLine = Common & {
  kind: 'key'; key: string; path: string; value: string;
  /** The line up to and including the colon. */
  head: string;
  /** What follows the value: spaces and the comment, or ''. */
  tail: string;
};
export type ItemLine = Common & { kind: 'item'; value: string; parent: string; head: string; tail: string };
export type OtherLine = Common & { kind: 'blank' | 'comment' };
export type DocLine = KeyLine | ItemLine | OtherLine;

export type Parsed = { ok: true; lines: DocLine[] } | { ok: false; error: string };
export type Edited = { ok: true; text: string } | { ok: false; error: string };

/** The value and its trailing comment: a quoted value ends at its closing quote, a plain one at ` #`. */
function splitValue(rest: string, where: string): { ok: true; value: string; tail: string } | { ok: false; error: string } {
  const lead = rest.length - rest.trimStart().length;
  const body = rest.slice(lead);
  if (body === '' || body.startsWith('#')) return { ok: true, value: '', tail: rest };
  const quote = body[0];
  if (quote === '"' || quote === "'") {
    const close = body.indexOf(quote, 1);
    if (close < 0) return { ok: false, error: `${where}: the quote is never closed` };
    const after = body.slice(close + 1);
    if (after.trim() !== '' && !/^\s+#/.test(after)) return { ok: false, error: `${where}: text after the closing quote` };
    return { ok: true, value: body.slice(0, close + 1), tail: after };
  }
  const hash = body.indexOf(' #');
  const value = (hash < 0 ? body : body.slice(0, hash)).trimEnd();
  return { ok: true, value, tail: body.slice(value.length) };
}

function checkValueShape(value: string, where: string): string | null {
  const first = value[0];
  if (first !== undefined && UNSUPPORTED_START[first] !== undefined) return `${where}: ${UNSUPPORTED_START[first]} is not in the flat format`;
  if (value.startsWith('[') !== value.endsWith(']')) return `${where}: an inline list must open with [ and close with ] on the same line`;
  if (value.startsWith('[') && /[[\]{}]/.test(value.slice(1, -1))) return `${where}: a list inside a list is not in the flat format`;
  return null;
}

/** Every line classified, with the dotted path of each key, or the first line that is not in the flat format. */
export function parseDocument(text: string): Parsed {
  if (text.includes('\r')) return { ok: false, error: 'the file has CR line ends; the flow reads LF only' };
  const lines: DocLine[] = [];
  /** The keys whose block is open, innermost last, with what their children are. */
  const open: { indent: number; path: string; empty: boolean; children: 'none' | 'keys' | 'items' }[] = [];
  const seen = new Set<string>();
  const raws = text.split('\n');
  for (let index = 0; index < raws.length; index += 1) {
    const raw = raws[index]!;
    const where = `line ${index + 1}`;
    const trimmed = raw.trim();
    const leading = raw.slice(0, raw.length - raw.trimStart().length);
    if (trimmed === '') { lines.push({ kind: 'blank', index, indent: 0, raw }); continue; }
    if (leading.includes('\t')) return { ok: false, error: `${where}: a tab in the indentation; use two spaces` };
    const indent = leading.length;
    if (trimmed.startsWith('#')) { lines.push({ kind: 'comment', index, indent, raw }); continue; }
    if (indent % INDENT !== 0) return { ok: false, error: `${where}: indented by ${indent} spaces; the flat format indents by two` };
    if (trimmed === '---' || trimmed === '...') return { ok: false, error: `${where}: document markers are not in the flat format` };
    while (open.length > 0 && open.at(-1)!.indent >= indent) open.pop();
    const parent = open.at(-1);
    if (indent > 0 && (parent === undefined || parent.indent + INDENT !== indent)) return { ok: false, error: `${where}: indented deeper than the key above it allows` };
    if (parent !== undefined && !parent.empty) return { ok: false, error: `${where}: ${parent.path} has a value on its own line and children under it` };
    if (trimmed === '-' || trimmed.startsWith('- ')) {
      if (parent === undefined) return { ok: false, error: `${where}: a list item with no key above it` };
      if (parent.children === 'keys') return { ok: false, error: `${where}: ${parent.path} mixes keys and list items` };
      parent.children = 'items';
      const head = `${leading}- `;
      const split = splitValue(raw.slice(head.length), where);
      if (!split.ok) return split;
      if (KEY.test(split.value) && /:( |$)/.test(split.value) && !/^["']/.test(split.value)) return { ok: false, error: `${where}: a list of maps is not in the flat format` };
      const shape = checkValueShape(split.value, where);
      if (shape !== null) return { ok: false, error: shape };
      lines.push({ kind: 'item', index, indent, raw, value: split.value, parent: parent.path, head, tail: split.tail });
      continue;
    }
    const match = KEY.exec(trimmed);
    if (match === null) return { ok: false, error: `${where}: not a key: value line` };
    const key = match[1]!;
    const rest = match[2]!;
    if (rest !== '' && !rest.startsWith(' ')) return { ok: false, error: `${where}: put a space after the colon of ${key}` };
    if (parent !== undefined) {
      if (parent.children === 'items') return { ok: false, error: `${where}: ${parent.path} mixes keys and list items` };
      parent.children = 'keys';
    }
    const path = parent === undefined ? key : `${parent.path}.${key}`;
    if (seen.has(path)) return { ok: false, error: `${where}: ${path} is set twice` };
    seen.add(path);
    const head = `${leading}${key}:`;
    const split = splitValue(rest, where);
    if (!split.ok) return split;
    const shape = checkValueShape(split.value, where);
    if (shape !== null) return { ok: false, error: shape };
    lines.push({ kind: 'key', index, indent, raw, key, path, value: split.value, head, tail: split.tail });
    open.push({ indent, path, empty: split.value === '', children: 'none' });
  }
  return { ok: true, lines };
}

/** The value a path holds in the parsed file, or undefined when it is absent. */
export function valueAt(map: YamlMap, path: string): YamlValue | undefined {
  let current: YamlValue | undefined = map;
  for (const key of path.split('.')) {
    if (current === undefined || typeof current !== 'object' || Array.isArray(current)) return undefined;
    current = current[key];
  }
  return current;
}

/** Every leaf path of the parsed file: a scalar, or a list (a list is one leaf). An empty map is a leaf too. */
export function leafPaths(map: YamlMap, prefix = ''): string[] {
  return Object.entries(map).flatMap(([key, value]) => {
    const path = prefix === '' ? key : `${prefix}.${key}`;
    if (typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length > 0) return leafPaths(value, path);
    return [path];
  });
}

/**
 * A scalar written so the flow reads it back the same: plain when it can be, else in quotes. A
 * value holding ` #` is refused: lib/flow.sh cuts a line there, quoted or not.
 */
export function formatScalar(value: string): { ok: true; text: string } | { ok: false; error: string } {
  if (value.includes('\n')) return { ok: false, error: 'a value cannot span lines in the flat format' };
  if (value.includes(' #')) return { ok: false, error: `"${value}" holds " #", which the flow reads as the start of a comment` };
  if (value === '') return { ok: true, text: '""' };
  const plain = !/^[\s"'#[\]{}&*!|>%@`,-]/.test(value) && !/\s$/.test(value) && !value.includes(': ') && !value.endsWith(':') && !value.startsWith('- ');
  if (plain) return { ok: true, text: value };
  if (!value.includes('"')) return { ok: true, text: `"${value}"` };
  if (!value.includes("'")) return { ok: true, text: `'${value}'` };
  return { ok: false, error: `"${value}" holds both quote marks, which the flat format cannot write` };
}

/** Where a key's block ends: its last child line, and any deeper comment lines right after it. */
function blockEnd(lines: DocLine[], key: KeyLine): number {
  let end = key.index;
  for (let index = key.index + 1; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (line.kind === 'blank') continue;
    if (line.indent <= key.indent) break;
    end = index;
  }
  return end;
}

function keyLine(lines: DocLine[], path: string): KeyLine | undefined {
  return lines.find((line): line is KeyLine => line.kind === 'key' && line.path === path);
}

function directChildren(lines: DocLine[], key: KeyLine): DocLine[] {
  const end = blockEnd(lines, key);
  return lines.slice(key.index + 1, end + 1).filter((line) => line.kind !== 'blank' && line.kind !== 'comment' && line.indent === key.indent + INDENT);
}

type Shape = 'scalar' | 'list' | 'map';

function formatAll(values: string[]): { ok: true; texts: string[] } | { ok: false; error: string } {
  const texts: string[] = [];
  for (const value of values) {
    const formatted = formatScalar(value);
    if (!formatted.ok) return formatted;
    texts.push(formatted.text);
  }
  return { ok: true, texts };
}

/** An inline list when every item can sit between commas, else null. */
function inlineList(values: string[]): string | null {
  const formatted = formatAll(values);
  if (!formatted.ok || values.some((value) => value.includes(',') || value.includes(']'))) return null;
  return `[${formatted.texts.join(', ')}]`;
}

/** The lines a new key and its value take, at `indent`. */
function newLines(key: string, indent: number, shape: Shape, value: Exclude<FieldValue, null>): { ok: true; lines: string[] } | { ok: false; error: string } {
  const pad = ' '.repeat(indent);
  if (shape === 'list') {
    const items = value as string[];
    const inline = inlineList(items);
    if (inline !== null) return { ok: true, lines: [`${pad}${key}: ${inline}`] };
    const formatted = formatAll(items);
    if (!formatted.ok) return formatted;
    return { ok: true, lines: [`${pad}${key}:`, ...formatted.texts.map((text) => `${pad}  - ${text}`)] };
  }
  if (shape === 'map') {
    const lines = [`${pad}${key}:`];
    for (const [child, entry] of Object.entries(value as Record<string, string>)) {
      const formatted = formatScalar(entry);
      if (!formatted.ok) return formatted;
      lines.push(`${pad}  ${child}: ${formatted.text}`);
    }
    return { ok: true, lines };
  }
  const formatted = formatScalar(String(value));
  return formatted.ok ? { ok: true, lines: [`${pad}${key}: ${formatted.text}`] } : formatted;
}

/** Puts a key that is not in the file under the deepest of its parents that is, after that parent's last line, or at the end of the file. */
function insert(raws: string[], lines: DocLine[], path: string, shape: Shape, value: Exclude<FieldValue, null>): Edited {
  const segments = path.split('.');
  let depth = segments.length - 1;
  let parent: KeyLine | undefined;
  while (depth > 0) {
    parent = keyLine(lines, segments.slice(0, depth).join('.'));
    if (parent !== undefined) break;
    depth -= 1;
  }
  if (parent !== undefined && (parent.value !== '' || directChildren(lines, parent).some((line) => line.kind === 'item'))) {
    return { ok: false, error: `${parent.path} holds a value, so ${path} cannot go under it` };
  }
  const baseIndent = parent === undefined ? 0 : parent.indent + INDENT;
  const added: string[] = [];
  segments.slice(depth, -1).forEach((segment, offset) => { added.push(`${' '.repeat(baseIndent + offset * INDENT)}${segment}:`); });
  const leaf = newLines(segments.at(-1)!, baseIndent + (segments.length - 1 - depth) * INDENT, shape, value);
  if (!leaf.ok) return leaf;
  added.push(...leaf.lines);
  const next = [...raws];
  if (parent !== undefined) {
    next.splice(blockEnd(lines, parent) + 1, 0, ...added);
  } else {
    // At the end of the file, before the empty string a final newline leaves.
    const at = next.length > 0 && next.at(-1) === '' ? next.length - 1 : next.length;
    next.splice(at, 0, ...added);
  }
  return { ok: true, text: next.join('\n') };
}

/** One change applied to the text: the value's line (or lines) rewritten in place, a new key inserted, or a key and its block taken out. */
export function applyChange(text: string, path: string, shape: Shape, value: FieldValue): Edited {
  const parsed = parseDocument(text);
  if (!parsed.ok) return parsed;
  const { lines } = parsed;
  const raws = text.split('\n');
  const key = keyLine(lines, path);
  if (value === null) {
    if (key === undefined) return { ok: true, text };
    const next = [...raws];
    next.splice(key.index, blockEnd(lines, key) - key.index + 1);
    return { ok: true, text: next.join('\n') };
  }
  if (key === undefined) return insert(raws, lines, path, shape, value);
  const children = directChildren(lines, key);
  const next = [...raws];
  if (shape === 'scalar') {
    if (children.length > 0) return { ok: false, error: `${path} is a ${children[0]!.kind === 'item' ? 'list' : 'map'} in the file; change it in Raw YAML` };
    const formatted = formatScalar(String(value));
    if (!formatted.ok) return formatted;
    next[key.index] = `${key.head} ${formatted.text}${key.tail}`;
    return { ok: true, text: next.join('\n') };
  }
  if (shape === 'list') {
    if (children.some((line) => line.kind === 'key')) return { ok: false, error: `${path} is a map in the file; change it in Raw YAML` };
    const items = value as string[];
    const itemLines = children.filter((line): line is ItemLine => line.kind === 'item');
    if (itemLines.length === 0) {
      const inline = inlineList(items);
      if (inline !== null) { next[key.index] = `${key.head} ${inline}${key.tail}`; return { ok: true, text: next.join('\n') }; }
      const block = newLines(key.key, key.indent, 'list', items);
      if (!block.ok) return block;
      next.splice(key.index, 1, `${key.head}${key.tail}`, ...block.lines.slice(1));
      return { ok: true, text: next.join('\n') };
    }
    if (items.length === 0) {
      for (const line of [...itemLines].reverse()) next.splice(line.index, 1);
      next[key.index] = `${key.head} []${key.tail}`;
      return { ok: true, text: next.join('\n') };
    }
    const formatted = formatAll(items);
    if (!formatted.ok) return formatted;
    // The item lines go, the new ones take the first one's place; comments between them stay.
    const first = itemLines[0]!;
    for (const line of [...itemLines].reverse()) next.splice(line.index, 1);
    next.splice(first.index, 0, ...formatted.texts.map((entry) => `${first.head}${entry}`));
    return { ok: true, text: next.join('\n') };
  }
  // A map: each child line keeps its place, its value rewritten; a child the change drops goes, a new one goes last.
  if (key.value !== '' || children.some((line) => line.kind === 'item')) return { ok: false, error: `${path} is not a map in the file; change it in Raw YAML` };
  const entries = value as Record<string, string>;
  const removals: [number, number][] = [];
  for (const child of children as KeyLine[]) {
    const wanted = entries[child.key];
    if (wanted === undefined) { removals.push([child.index, blockEnd(lines, child) - child.index + 1]); continue; }
    if (directChildren(lines, child).length > 0) {
      return { ok: false, error: `${child.path} has lines under it (such as command and paths); change it in Raw YAML` };
    }
    const formatted = formatScalar(wanted);
    if (!formatted.ok) return formatted;
    next[child.index] = `${child.head} ${formatted.text}${child.tail}`;
  }
  const known = new Set((children as KeyLine[]).map((child) => child.key));
  const added: string[] = [];
  for (const [child, entry] of Object.entries(entries)) {
    if (known.has(child)) continue;
    const formatted = formatScalar(entry);
    if (!formatted.ok) return formatted;
    added.push(`${' '.repeat(key.indent + INDENT)}${child}: ${formatted.text}`);
  }
  next.splice(blockEnd(lines, key) + 1, 0, ...added);
  for (const [at, count] of removals.reverse()) next.splice(at, count);
  return { ok: true, text: next.join('\n') };
}

/** Whether the parsed file holds `value` at `path`, as the flow would read it back. */
export function readsBack(text: string, path: string, shape: Shape, value: FieldValue): boolean {
  const found = valueAt(parseYaml(text), path);
  if (value === null) return found === undefined;
  if (shape === 'scalar') return found === String(value);
  return JSON.stringify(found) === JSON.stringify(value);
}
