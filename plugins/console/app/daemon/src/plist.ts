/**
 * A property list's value: a `<string>`, `<date>` or `<data>` as its text, an `<integer>` or
 * `<real>` as a number, `<true/>` and `<false/>`, an `<array>`, a `<dict>`.
 */
export type PlistValue = string | number | boolean | readonly PlistValue[] | PlistDictionary;
export type PlistDictionary = { readonly [key: string]: PlistValue };

type Token = { kind: 'open' | 'close' | 'empty'; name: string } | { kind: 'text'; text: string };

const ELEMENT = /<(\/?)([a-z]+)(\/?)>|([^<]+)/g;
const BLANK = /^\s*$/;
const INFINITY = /^[+-]?inf(?:inity)?$/;
const NOT_A_NUMBER = 'nan';
const ENTITY = /&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g;
const NAMED_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
const HEXADECIMAL = 16;
const DECIMAL = 10;
const LAST_CODE_POINT = 0x10ffff;

/**
 * The value of an XML property list, as `plutil -convert xml1` and `defaults export` write one;
 * null when the text is not one. Comments and processing instructions inside the `<plist>` are not read.
 */
export function parsePlistXml(xml: string): PlistValue | null {
  const tokens = plistTokens(xml);
  if (tokens === null) return null;
  const reader = new TokenReader(tokens);
  const value = readValue(reader, reader.nextElement());
  if (value === undefined || reader.nextElement() !== undefined) return null;
  return value;
}

/** Whether the value is a `<dict>`. */
export function isPlistDictionary(value: PlistValue | undefined): value is PlistDictionary {
  return typeof value === 'object' && !Array.isArray(value);
}

function plistTokens(xml: string): Token[] | null {
  const open = xml.indexOf('<plist');
  const bodyStart = open < 0 ? -1 : xml.indexOf('>', open);
  const bodyEnd = xml.lastIndexOf('</plist>');
  if (bodyStart < 0 || bodyEnd < bodyStart) return null;
  return [...xml.slice(bodyStart + 1, bodyEnd).matchAll(ELEMENT)].map(token);
}

function token(match: RegExpExecArray): Token {
  const [, closing, name, empty, text] = match;
  if (text !== undefined) return { kind: 'text', text };
  if (closing === '/') return { kind: 'close', name: name! };
  return { kind: empty === '/' ? 'empty' : 'open', name: name! };
}

/** The tokens in order; whitespace between elements is skipped, text inside one is kept. */
class TokenReader {
  private readonly tokens: readonly Token[];
  private next = 0;

  constructor(tokens: readonly Token[]) {
    this.tokens = tokens;
  }

  /** Takes the next element tag, past the whitespace before it. */
  nextElement(): Token | undefined {
    while (this.isBlankText(this.tokens[this.next])) this.next += 1;
    const found = this.tokens[this.next];
    this.next += 1;
    return found;
  }

  /** Takes the element's text and its closing tag; '' when it closes at once, undefined when anything else follows. */
  textUntilClose(name: string): string | undefined {
    const first = this.tokens[this.next];
    const text = first?.kind === 'text' ? first.text : '';
    if (first?.kind === 'text') this.next += 1;
    const closing = this.tokens[this.next];
    this.next += 1;
    return closing?.kind === 'close' && closing.name === name ? decodeEntities(text) : undefined;
  }

  private isBlankText(candidate: Token | undefined): boolean {
    return candidate?.kind === 'text' && BLANK.test(candidate.text);
  }
}

function readValue(reader: TokenReader, start: Token | undefined): PlistValue | undefined {
  if (start?.kind === 'empty') return emptyValue(start.name);
  if (start?.kind !== 'open') return undefined;
  switch (start.name) {
    case 'dict': return readDictionary(reader);
    case 'array': return readArray(reader);
    case 'string': case 'date': case 'data': return reader.textUntilClose(start.name);
    case 'integer': case 'real': return numberValue(reader.textUntilClose(start.name));
    default: return undefined;
  }
}

function emptyValue(name: string): PlistValue | undefined {
  switch (name) {
    case 'true': return true;
    case 'false': return false;
    case 'dict': return {};
    case 'array': return [];
    case 'string': return '';
    default: return undefined;
  }
}

/** A number's text; a `<real>` may also be `+infinity`, `-infinity` or `nan`, as Foundation writes them. */
function numberValue(text: string | undefined): number | undefined {
  if (text === undefined || BLANK.test(text)) return undefined;
  const spelt = text.trim().toLowerCase();
  return specialReal(spelt) ?? decimalNumber(spelt);
}

function specialReal(spelt: string): number | undefined {
  if (INFINITY.test(spelt)) return spelt.startsWith('-') ? Number.NEGATIVE_INFINITY : Number.POSITIVE_INFINITY;
  return spelt === NOT_A_NUMBER ? Number.NaN : undefined;
}

function decimalNumber(spelt: string): number | undefined {
  const value = Number(spelt);
  return Number.isNaN(value) ? undefined : value;
}

function readDictionary(reader: TokenReader): PlistDictionary | undefined {
  const entries: Record<string, PlistValue> = {};
  for (let start = reader.nextElement(); start !== undefined; start = reader.nextElement()) {
    if (start.kind === 'close') return start.name === 'dict' ? entries : undefined;
    const entry = readEntry(reader, start);
    if (entry === undefined) return undefined;
    entries[entry.key] = entry.value;
  }
  return undefined;
}

function readEntry(reader: TokenReader, start: Token): { key: string; value: PlistValue } | undefined {
  if (start.kind !== 'open' || start.name !== 'key') return undefined;
  const key = reader.textUntilClose('key');
  if (key === undefined) return undefined;
  const value = readValue(reader, reader.nextElement());
  return value === undefined ? undefined : { key, value };
}

function readArray(reader: TokenReader): PlistValue[] | undefined {
  const values: PlistValue[] = [];
  for (let start = reader.nextElement(); start !== undefined; start = reader.nextElement()) {
    if (start.kind === 'close') return start.name === 'array' ? values : undefined;
    const value = readValue(reader, start);
    if (value === undefined) return undefined;
    values.push(value);
  }
  return undefined;
}

function decodeEntities(text: string): string {
  return text.replace(ENTITY, (_entity, name: string) => {
    if (name.startsWith('#x')) return codePointText(Number.parseInt(name.slice(2), HEXADECIMAL));
    if (name.startsWith('#')) return codePointText(Number.parseInt(name.slice(1), DECIMAL));
    return NAMED_ENTITIES[name] ?? '';
  });
}

function codePointText(codePoint: number): string {
  return codePoint <= LAST_CODE_POINT ? String.fromCodePoint(codePoint) : '';
}
