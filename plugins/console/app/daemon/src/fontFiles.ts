import { open, readdir } from 'node:fs/promises';
import path from 'node:path';

/** A font file the page can load as a web font, with the content type it is served as. */
export type FontFile = { path: string; contentType: FontContentType };
export type FontContentType = 'font/ttf' | 'font/otf';

type FontNames = { postScriptNames: string[]; servedAs: FontContentType };

type ByteReader = (offset: number, length: number) => Promise<Uint8Array>;

/** Finds the first font file, by the order of the names, whose PostScript name is one of them; null when none is there to serve. */
export type FontLookup = (postScriptNames: readonly string[]) => Promise<FontFile | null>;

const FONT_EXTENSIONS = new Set(['.ttf', '.otf', '.ttc', '.otc']);
const CFF_TAG = 'OTTO';
const TRUETYPE_VERSION = 0x00010000;
const APPLE_TRUETYPE_TAG = 'true';
const NAME_TABLE_TAG = 'name';
const POSTSCRIPT_NAME_ID = 6;
const MAC_PLATFORM_ID = 1;
const SFNT_HEADER_BYTES = 12;
const TABLE_RECORD_BYTES = 16;
const NAME_HEADER_BYTES = 6;
const NAME_RECORD_BYTES = 12;
const TAG_BYTES = 4;
const SFNT_TABLE_COUNT_AT = 4;
const RECORD_OFFSET_AT = 8;
const RECORD_LENGTH_AT = 12;
const NAME_COUNT_AT = 2;
const NAME_STRINGS_AT = 4;
const NAME_ID_AT = 6;
const NAME_STRING_LENGTH_AT = 8;
const NAME_STRING_OFFSET_AT = 10;
/** Bounds on what a malformed file can make the reader ask for. */
const TABLES_MAXIMUM = 512;
const NAME_TABLE_BYTES_MAXIMUM = 1024 * 1024;
const ascii = new TextDecoder('latin1');
const utf16 = new TextDecoder('utf-16be');

/**
 * The machine's font folders in the order macOS looks: the user's, the machine's, the system's.
 * Their subfolders are searched too.
 */
export function macFontFolders(home: string): string[] {
  return [path.join(home, 'Library', 'Fonts'), '/Library/Fonts', '/System/Library/Fonts'];
}

/**
 * A lookup over the font folders: it reads each font file's name table, never trusts its file
 * name, and stops at a file with the first name. A collection is skipped by its tag, unread.
 */
export function folderFontLookup(folders: readonly string[]): FontLookup {
  return async (postScriptNames) => bestFont(await fontFilesIn(folders), postScriptNames);
}

type RankedFont = { rank: number; file: FontFile | null };

async function bestFont(files: readonly string[], wanted: readonly string[]): Promise<FontFile | null> {
  let best: RankedFont = { rank: wanted.length, file: null };
  for (const file of files) {
    if (best.rank === 0) break;
    best = (await rankedFont(file, wanted, best.rank)) ?? best;
  }
  return best.file;
}

async function rankedFont(file: string, wanted: readonly string[], toBeat: number): Promise<RankedFont | null> {
  const found = await fileNames(file);
  if (found === null) return null;
  const rank = firstRank(wanted, found.postScriptNames);
  return rank < 0 || rank >= toBeat ? null : { rank, file: { path: file, contentType: found.servedAs } };
}

function firstRank(wanted: readonly string[], held: readonly string[]): number {
  return wanted.findIndex((name) => held.includes(name));
}

async function fontFilesIn(folders: readonly string[]): Promise<string[]> {
  const files: string[] = [];
  for (const folder of folders) {
    const entries = await readdir(folder, { recursive: true }).catch(() => [] as string[]);
    files.push(...entries.filter((entry) => FONT_EXTENSIONS.has(path.extname(entry).toLowerCase())).sort().map((entry) => path.join(folder, entry)));
  }
  return files;
}

async function fileNames(file: string): Promise<FontNames | null> {
  const handle = await open(file, 'r').catch(() => null);
  if (handle === null) return null;
  try {
    return await fontNames(async (offset, length) => {
      const buffer = new Uint8Array(length);
      const { bytesRead } = await handle.read(buffer, 0, length, offset);
      return buffer.subarray(0, bytesRead);
    });
  } catch {
    return null;
  } finally {
    await handle.close().catch(() => undefined);
  }
}

/** A collection (.ttc) is null from its tag alone: a web font cannot load one. */
async function fontNames(read: ByteReader): Promise<FontNames | null> {
  const header = await read(0, SFNT_HEADER_BYTES);
  if (header.length < SFNT_HEADER_BYTES) return null;
  const kind = fontKind(header);
  if (kind === null) return null;
  const name = await postScriptName(read, 0);
  return { postScriptNames: name === null ? [] : [name], servedAs: kind };
}

function fontKind(header: Uint8Array): FontContentType | null {
  const tag = tagOf(header, 0);
  if (tag === CFF_TAG) return 'font/otf';
  return tag === APPLE_TRUETYPE_TAG || view(header).getUint32(0) === TRUETYPE_VERSION ? 'font/ttf' : null;
}

/** The PostScript name (name id 6) of the font whose table directory starts at `start`. */
async function postScriptName(read: ByteReader, start: number): Promise<string | null> {
  const header = await read(start, SFNT_HEADER_BYTES);
  if (header.length < SFNT_HEADER_BYTES) return null;
  const tableCount = Math.min(view(header).getUint16(SFNT_TABLE_COUNT_AT), TABLES_MAXIMUM);
  const records = await read(start + SFNT_HEADER_BYTES, tableCount * TABLE_RECORD_BYTES);
  for (let at = 0; at + TABLE_RECORD_BYTES <= records.length; at += TABLE_RECORD_BYTES) {
    if (tagOf(records, at) !== NAME_TABLE_TAG) continue;
    const table = await read(view(records).getUint32(at + RECORD_OFFSET_AT), Math.min(view(records).getUint32(at + RECORD_LENGTH_AT), NAME_TABLE_BYTES_MAXIMUM));
    return nameRecord(table, POSTSCRIPT_NAME_ID);
  }
  return null;
}

/** The first non-empty string with the name id in a name table: UTF-16 on the Unicode and Windows platforms, one byte a character on the Mac one. */
function nameRecord(table: Uint8Array, nameId: number): string | null {
  if (table.length < NAME_HEADER_BYTES) return null;
  const fields = view(table);
  const end = Math.min(table.length, NAME_HEADER_BYTES + fields.getUint16(NAME_COUNT_AT) * NAME_RECORD_BYTES);
  for (let at = NAME_HEADER_BYTES; at + NAME_RECORD_BYTES <= end; at += NAME_RECORD_BYTES) {
    if (fields.getUint16(at + NAME_ID_AT) !== nameId) continue;
    const text = recordText(table, at);
    if (text !== '') return text;
  }
  return null;
}

function recordText(table: Uint8Array, at: number): string {
  const fields = view(table);
  const from = fields.getUint16(NAME_STRINGS_AT) + fields.getUint16(at + NAME_STRING_OFFSET_AT);
  const bytes = table.subarray(from, from + fields.getUint16(at + NAME_STRING_LENGTH_AT));
  return (fields.getUint16(at) === MAC_PLATFORM_ID ? ascii : utf16).decode(bytes).trim();
}

function tagOf(bytes: Uint8Array, at: number): string {
  return ascii.decode(bytes.subarray(at, at + TAG_BYTES));
}

function view(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}
