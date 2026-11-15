import { open, readdir } from 'node:fs/promises';
import path from 'node:path';

/** A font file the page can load as a web font, with the content type it is served as. */
export type FontFile = { path: string; contentType: FontContentType };
export type FontContentType = 'font/ttf' | 'font/otf';

/**
 * The PostScript names a font file holds, and the content type it is served as: null for a
 * collection (.ttc), which holds one name per font and which a web font cannot load.
 */
export type FontNames = { postScriptNames: string[]; servedAs: FontContentType | null };

/** Reads up to `length` bytes at `offset`; fewer at the end of the file. */
export type ByteReader = (offset: number, length: number) => Promise<Uint8Array>;

/** Finds the first font file, by the order of the names, whose PostScript name is one of them; null when none is there to serve. */
export type FontLookup = (postScriptNames: readonly string[]) => Promise<FontFile | null>;

const FONT_EXTENSIONS = new Set(['.ttf', '.otf', '.ttc', '.otc']);
const COLLECTION_TAG = 'ttcf';
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
const COLLECTION_HEADER_BYTES = 12;
const OFFSET_BYTES = 4;
/** Bounds on what a malformed file can make the reader ask for. */
const COLLECTION_FONTS_MAXIMUM = 256;
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
 * name, and stops at a file with the first name. A name found only in a collection is skipped.
 */
export function folderFontLookup(folders: readonly string[]): FontLookup {
  return async (postScriptNames) => {
    let best: { rank: number; file: FontFile } | null = null;
    for (const file of await fontFilesIn(folders)) {
      const found = await fileNames(file);
      if (found === null || found.servedAs === null) continue;
      const rank = firstRank(postScriptNames, found.postScriptNames);
      if (rank < 0 || (best !== null && best.rank <= rank)) continue;
      best = { rank, file: { path: file, contentType: found.servedAs } };
      if (rank === 0) break;
    }
    return best?.file ?? null;
  };
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
    await handle.close();
  }
}

/** The PostScript names a font file holds, from its name table; null when it is not a TrueType, OpenType or collection file. */
export async function fontNames(read: ByteReader): Promise<FontNames | null> {
  const header = await read(0, COLLECTION_HEADER_BYTES);
  if (header.length < SFNT_HEADER_BYTES) return null;
  const tag = tagOf(header, 0);
  if (tag === COLLECTION_TAG) return { postScriptNames: await collectionNames(read, header), servedAs: null };
  if (tag !== CFF_TAG && tag !== APPLE_TRUETYPE_TAG && view(header).getUint32(0) !== TRUETYPE_VERSION) return null;
  const name = await postScriptName(read, 0);
  return { postScriptNames: name === null ? [] : [name], servedAs: tag === CFF_TAG ? 'font/otf' : 'font/ttf' };
}

async function collectionNames(read: ByteReader, header: Uint8Array): Promise<string[]> {
  const count = Math.min(view(header).getUint32(8), COLLECTION_FONTS_MAXIMUM);
  const offsets = await read(COLLECTION_HEADER_BYTES, count * OFFSET_BYTES);
  const names: string[] = [];
  for (let index = 0; index + OFFSET_BYTES <= offsets.length; index += OFFSET_BYTES) {
    const name = await postScriptName(read, view(offsets).getUint32(index));
    if (name !== null) names.push(name);
  }
  return names;
}

/** The PostScript name (name id 6) of the font whose table directory starts at `start`. */
async function postScriptName(read: ByteReader, start: number): Promise<string | null> {
  const header = await read(start, SFNT_HEADER_BYTES);
  if (header.length < SFNT_HEADER_BYTES) return null;
  const tableCount = Math.min(view(header).getUint16(4), TABLES_MAXIMUM);
  const records = await read(start + SFNT_HEADER_BYTES, tableCount * TABLE_RECORD_BYTES);
  for (let at = 0; at + TABLE_RECORD_BYTES <= records.length; at += TABLE_RECORD_BYTES) {
    if (tagOf(records, at) !== NAME_TABLE_TAG) continue;
    const table = await read(view(records).getUint32(at + 8), Math.min(view(records).getUint32(at + 12), NAME_TABLE_BYTES_MAXIMUM));
    return nameRecord(table, POSTSCRIPT_NAME_ID);
  }
  return null;
}

/** The first non-empty string with the name id in a name table: UTF-16 on the Unicode and Windows platforms, one byte a character on the Mac one. */
function nameRecord(table: Uint8Array, nameId: number): string | null {
  if (table.length < NAME_HEADER_BYTES) return null;
  const count = view(table).getUint16(2);
  const strings = view(table).getUint16(4);
  for (let at = NAME_HEADER_BYTES; at + NAME_RECORD_BYTES <= table.length && at < NAME_HEADER_BYTES + count * NAME_RECORD_BYTES; at += NAME_RECORD_BYTES) {
    const record = view(table);
    if (record.getUint16(at + 6) !== nameId) continue;
    const from = strings + record.getUint16(at + 10);
    const bytes = table.subarray(from, from + record.getUint16(at + 8));
    const text = (record.getUint16(at) === MAC_PLATFORM_ID ? ascii : utf16).decode(bytes).trim();
    if (text !== '') return text;
  }
  return null;
}

function tagOf(bytes: Uint8Array, at: number): string {
  return ascii.decode(bytes.subarray(at, at + OFFSET_BYTES));
}

function view(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}
