import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { realScheduler } from '../src/actions.ts';
import type { FontFile } from '../src/fontFiles.ts';
import { silentLogger } from '../src/log.ts';
import { PaneSessions } from '../src/panes.ts';
import { ProjectRegistry } from '../src/registry.ts';
import { closeConsoleServer, createConsoleServer } from '../src/server.ts';
import { TerminalProfiles } from '../src/terminalProfiles.ts';
import type { TerminalProfileReaders } from '../src/terminalProfiles.ts';
import { TERMINAL_FONT_PATH, TERMINAL_PROFILE_PATH } from '../src/terminalProtocol.ts';
import type { TerminalProfile } from '../src/terminalProtocol.ts';

const TOKEN = 'tok';
const AUTHORISED = { authorization: `Bearer ${TOKEN}` };
const GUID = 'D0D0D0D0-1380-4000-8000-000000000001';
/** Bytes no real font starts with, so a served file is visibly this one. */
const FONT_BYTES = Buffer.from([0x00, 0x01, 0x00, 0x00, 0x13, 0x8f, 0x0e, 0x5e, 0xff, 0x00, 0x7a]);

type Rig = { base: string; fontFile: FontFile; otherFile: string; close: () => Promise<void> };

/** A console server with no projects whose terminal look is iTerm's profile and one font file in a temp folder, or no font when `withFont` is false. */
async function started(withFont = true): Promise<Rig> {
  const folder = mkdtempSync(path.join(os.tmpdir(), 'console-terminal-routes-'));
  const fontFile: FontFile = { path: path.join(folder, 'served.ttf'), contentType: 'font/ttf' };
  const otherFile = path.join(folder, 'secret.txt');
  writeFileSync(fontFile.path, FONT_BYTES);
  writeFileSync(otherFile, 'not for the page');
  const readers: TerminalProfileReaders = {
    readItermPreferences: async () => ({ 'Default Bookmark Guid': GUID, 'New Bookmarks': [{ Guid: GUID, 'Normal Font': 'Served-Regular 14', 'Blinking Cursor': true }] }),
    findFont: async () => (withFont ? fontFile : null),
  };
  const registry = new ProjectRegistry(() => { throw new Error('this test serves no project'); }, silentLogger);
  const panes = new PaneSessions({ spawner: () => ({ ok: false, error: 'this test opens no pane' }), host: { shell: '/bin/sh', environment: {}, isFolder: () => false }, scheduler: realScheduler, log: silentLogger });
  const server = createConsoleServer(registry, null, { host: '127.0.0.1', port: 0, token: TOKEN, staticDir: null, log: silentLogger, panes, terminal: new TerminalProfiles(readers, silentLogger) });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, fontFile, otherFile, close: async () => { await closeConsoleServer(server); rmSync(folder, { recursive: true, force: true }); } };
}

test('ProfileRoute_WithToken_ServesTheProfile', async () => {
  const rig = await started();
  try {
    const profile = (await (await fetch(`${rig.base}${TERMINAL_PROFILE_PATH}`, { headers: AUTHORISED })).json()) as TerminalProfile;
    assert.deepEqual({ fontSize: profile.iterm?.fontSize, cursorBlink: profile.iterm?.cursorBlink, font: profile.font }, { fontSize: 14, cursorBlink: true, font: { path: TERMINAL_FONT_PATH } },
      'because the page builds its panes from iTerm\'s look and the route the font is served at');
  } finally { await rig.close(); }
});

test('TerminalRoutes_WithoutToken_401', async () => {
  const rig = await started();
  try {
    for (const route of [TERMINAL_PROFILE_PATH, TERMINAL_FONT_PATH]) {
      assert.equal((await fetch(`${rig.base}${route}`)).status, 401, `because ${route} sits behind the same token as the rest of the API`);
    }
  } finally { await rig.close(); }
});

test('FontRoute_WithToken_ServesTheResolvedFilesBytes', async () => {
  const rig = await started();
  try {
    const response = await fetch(`${rig.base}${TERMINAL_FONT_PATH}`, { headers: AUTHORISED });
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), FONT_BYTES, 'because the page loads the font file the daemon found, byte for byte');
  } finally { await rig.close(); }
});

test('FontRoute_WithToken_ServedAsItsContentType', async () => {
  const rig = await started();
  try {
    const response = await fetch(`${rig.base}${TERMINAL_FONT_PATH}`, { headers: AUTHORISED });
    await response.arrayBuffer();
    assert.equal(response.headers.get('content-type'), rig.fontFile.contentType, 'because a browser loads a web font only with a font content type');
  } finally { await rig.close(); }
});

test('FontRoute_RequestNamingAnotherFile_StillServesOnlyTheResolvedFont', async () => {
  const rig = await started();
  try {
    for (const key of ['path', 'file', 'font']) {
      const response = await fetch(`${rig.base}${TERMINAL_FONT_PATH}?${key}=${encodeURIComponent(rig.otherFile)}`, { headers: AUTHORISED });
      assert.deepEqual(Buffer.from(await response.arrayBuffer()), FONT_BYTES, `because no request value picks a file: a ${key} naming another file still gets the resolved font`);
    }
  } finally { await rig.close(); }
});

test('FontRoute_NoFontResolved_404', async () => {
  const rig = await started(false);
  try {
    assert.equal((await fetch(`${rig.base}${TERMINAL_FONT_PATH}`, { headers: AUTHORISED })).status, 404, 'because with no font to serve the page keeps its own fonts');
  } finally { await rig.close(); }
});

test('TerminalRoutes_NotGet_405', async () => {
  const rig = await started();
  try {
    for (const route of [TERMINAL_PROFILE_PATH, TERMINAL_FONT_PATH]) {
      const response = await fetch(`${rig.base}${route}`, { method: 'POST', headers: { ...AUTHORISED, 'content-type': 'application/json' }, body: '{}' });
      assert.equal(response.status, 405, `because ${route} only reads; nothing the page sends changes the look or the file`);
    }
  } finally { await rig.close(); }
});
