import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { folderFontLookup, fontNames } from '../src/fontFiles.ts';
import type { ByteReader } from '../src/fontFiles.ts';

type NameRecord = { platform: 'windows' | 'mac'; nameId: number; text: string };
type Outline = 'truetype' | 'cff';

const POSTSCRIPT = 6;
const FAMILY = 1;

/** A name table as the OpenType spec lays it out: format 0, the records, then their strings. */
function nameTable(records: readonly NameRecord[]): Buffer {
  const strings = records.map((record) => record.platform === 'windows' ? Buffer.from(record.text, 'utf16le').swap16() : Buffer.from(record.text, 'latin1'));
  const header = Buffer.alloc(6 + records.length * 12);
  header.writeUInt16BE(0, 0);
  header.writeUInt16BE(records.length, 2);
  header.writeUInt16BE(header.length, 4);
  let stringOffset = 0;
  records.forEach((record, index) => {
    const text = strings[index] ?? Buffer.alloc(0);
    const at = 6 + index * 12;
    const windows = record.platform === 'windows';
    header.writeUInt16BE(windows ? 3 : 1, at);
    header.writeUInt16BE(windows ? 1 : 0, at + 2);
    header.writeUInt16BE(windows ? 0x409 : 0, at + 4);
    header.writeUInt16BE(record.nameId, at + 6);
    header.writeUInt16BE(text.length, at + 8);
    header.writeUInt16BE(stringOffset, at + 10);
    stringOffset += text.length;
  });
  return Buffer.concat([header, ...strings]);
}

/** One font as it sits at `start` in its file: the sfnt header, a stub head table, then its name table. */
function sfnt(outline: Outline, records: readonly NameRecord[], start = 0): Buffer {
  const names = nameTable(records);
  const head = Buffer.alloc(54);
  const directory = Buffer.alloc(12 + 2 * 16);
  if (outline === 'truetype') directory.writeUInt32BE(0x00010000, 0); else directory.write('OTTO', 0, 'latin1');
  directory.writeUInt16BE(2, 4);
  directory.write('head', 12, 'latin1');
  directory.writeUInt32BE(start + directory.length, 12 + 8);
  directory.writeUInt32BE(head.length, 12 + 12);
  directory.write('name', 28, 'latin1');
  directory.writeUInt32BE(start + directory.length + head.length, 28 + 8);
  directory.writeUInt32BE(names.length, 28 + 12);
  return Buffer.concat([directory, head, names]);
}

/** A .ttc holding these fonts, each by its PostScript name. */
function collection(postScriptNames: readonly string[]): Buffer {
  const header = Buffer.alloc(12 + postScriptNames.length * 4);
  header.write('ttcf', 0, 'latin1');
  header.writeUInt32BE(0x00010000, 4);
  header.writeUInt32BE(postScriptNames.length, 8);
  const fonts: Buffer[] = [];
  let start = header.length;
  postScriptNames.forEach((name, index) => {
    header.writeUInt32BE(start, 12 + index * 4);
    const font = sfnt('truetype', [{ platform: 'windows', nameId: POSTSCRIPT, text: name }], start);
    fonts.push(font);
    start += font.length;
  });
  return Buffer.concat([header, ...fonts]);
}

function readerOver(bytes: Buffer): ByteReader {
  return async (offset, length) => new Uint8Array(bytes.subarray(offset, offset + length));
}

function postScriptFont(name: string, outline: Outline = 'truetype'): Buffer {
  return sfnt(outline, [{ platform: 'windows', nameId: FAMILY, text: 'Family Not Wanted' }, { platform: 'windows', nameId: POSTSCRIPT, text: name }]);
}

/** A temp font folder holding `files`, removed after `body` runs. */
async function inFontFolder(files: Record<string, Buffer>, body: (folder: string) => Promise<void>): Promise<void> {
  const folder = mkdtempSync(path.join(os.tmpdir(), 'console-fonts-'));
  try {
    for (const [name, bytes] of Object.entries(files)) {
      mkdirSync(path.dirname(path.join(folder, name)), { recursive: true });
      writeFileSync(path.join(folder, name), bytes);
    }
    await body(folder);
  } finally { rmSync(folder, { recursive: true, force: true }); }
}

test('TrueTypeFont_NamesItsPostScriptNameAndServesAsTtf', async () => {
  assert.deepEqual(await fontNames(readerOver(postScriptFont('JetBrainsMonoNF-Regular'))), { postScriptNames: ['JetBrainsMonoNF-Regular'], servedAs: 'font/ttf' },
    'because a TrueType file is found by name ID 6 alone, not its family name, and the page loads it as font/ttf');
});

test('CffFont_NamesItsPostScriptNameAndServesAsOtf', async () => {
  assert.deepEqual(await fontNames(readerOver(postScriptFont('SourceCodePro-Regular', 'cff'))), { postScriptNames: ['SourceCodePro-Regular'], servedAs: 'font/otf' },
    'because an OTTO file is an OpenType font with CFF outlines, served as font/otf');
});

test('MacRomanNameRecord_Decoded', async () => {
  const font = sfnt('truetype', [{ platform: 'mac', nameId: POSTSCRIPT, text: 'Menlo-Regular' }]);
  assert.deepEqual((await fontNames(readerOver(font)))?.postScriptNames ?? 'no names', ['Menlo-Regular'], 'because older fonts carry their PostScript name as a one-byte Mac record');
});

test('Collection_NoNames', async () => {
  assert.equal(await fontNames(readerOver(collection(['Menlo-Regular', 'Menlo-Bold']))), null,
    'because a web font cannot load a collection, so its names are not worth reading');
});

test('BytesThatAreNotAFont_NoNames', async () => {
  const junk: Record<string, Buffer> = { text: Buffer.from('this is not a font file at all, only words'), empty: Buffer.alloc(0) };
  for (const [shape, bytes] of Object.entries(junk)) {
    assert.equal(await fontNames(readerOver(bytes)), null, `because ${shape} names no font, and reading it must not throw`);
  }
});

test('FontCutOffBeforeItsNameTable_NamesNoPostScriptName', async () => {
  const cut = postScriptFont('Cut-Regular').subarray(0, 40);
  assert.deepEqual((await fontNames(readerOver(cut)))?.postScriptNames ?? [], [], 'because a file that ends before its name table holds no name that a lookup could match');
});

test('FontLookup_FileNamedOtherwise_FoundByTheNameInside', async () => {
  await inFontFolder({ 'Menlo.ttf': postScriptFont('JetBrainsMonoNF-Regular'), 'JetBrainsMonoNF-Regular.ttf': postScriptFont('Impostor-Regular') }, async (folder) => {
    assert.deepEqual(await folderFontLookup([folder])(['JetBrainsMonoNF-Regular']), { path: path.join(folder, 'Menlo.ttf'), contentType: 'font/ttf' },
      'because a file name proves nothing; the font named inside the file is the one served');
  });
});

test('FontLookup_EarlierWantedNameInAFileThatSortsLater_Wins', async () => {
  await inFontFolder({ 'a-console.ttf': postScriptFont('ConsoleFont-Regular'), 'z-iterm.otf': postScriptFont('ItermFont-Regular', 'cff') }, async (folder) => {
    assert.deepEqual(await folderFontLookup([folder])(['ItermFont-Regular', 'ConsoleFont-Regular']), { path: path.join(folder, 'z-iterm.otf'), contentType: 'font/otf' },
      'because iTerm\'s own font comes before the console\'s fallback whatever order the files are found in');
  });
});

test('FontLookup_FontInASubfolder_Found', async () => {
  await inFontFolder({ 'Nerd Fonts/JetBrains/font.ttf': postScriptFont('JetBrainsMonoNF-Regular') }, async (folder) => {
    assert.equal((await folderFontLookup([folder])(['JetBrainsMonoNF-Regular']))?.path ?? 'not found', path.join(folder, 'Nerd Fonts/JetBrains/font.ttf'),
      'because font installers put fonts in subfolders of the font folders');
  });
});

test('FontLookup_NameOnlyInACollection_NotServed', async () => {
  await inFontFolder({ 'Menlo.ttc': collection(['Menlo-Regular', 'Menlo-Bold']) }, async (folder) => {
    assert.equal(await folderFontLookup([folder])(['Menlo-Regular']), null, 'because a collection cannot be loaded as a web font, so it is not a file to serve');
  });
});

test('FontLookup_NameOnlyInACollection_LaterNameInAPlainFileServed', async () => {
  await inFontFolder({ 'Menlo.ttc': collection(['Menlo-Regular']), 'console.ttf': postScriptFont('ConsoleFont-Regular') }, async (folder) => {
    assert.equal((await folderFontLookup([folder])(['Menlo-Regular', 'ConsoleFont-Regular']))?.path ?? 'not found', path.join(folder, 'console.ttf'),
      'because skipping the collection falls back to the next wanted name rather than to nothing');
  });
});

test('FontLookup_NoFileHoldsAWantedName_Null', async () => {
  await inFontFolder({ 'other.ttf': postScriptFont('Other-Regular'), 'notes.txt': Buffer.from('JetBrainsMonoNF-Regular') }, async (folder) => {
    assert.equal(await folderFontLookup([folder])(['JetBrainsMonoNF-Regular']), null, 'because no font file there holds the name, so there is nothing to serve');
  });
});

test('FontLookup_MissingFolder_NullWithoutThrowing', async () => {
  const missing = path.join(os.tmpdir(), `console-fonts-missing-${process.pid}`, 'Library', 'Fonts');
  assert.equal(await folderFontLookup([missing])(['JetBrainsMonoNF-Regular']), null, 'because a machine without a user font folder must still start, serving no font');
});

test('FontLookup_MissingFolderBeforeOneWithTheFont_FontFound', async () => {
  await inFontFolder({ 'font.ttf': postScriptFont('JetBrainsMonoNF-Regular') }, async (folder) => {
    const missing = path.join(folder, 'no-such-folder');
    assert.equal((await folderFontLookup([missing, folder])(['JetBrainsMonoNF-Regular']))?.path ?? 'not found', path.join(folder, 'font.ttf'),
      'because one missing folder must not stop the search of the others');
  });
});
