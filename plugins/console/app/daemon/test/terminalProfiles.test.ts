import assert from 'node:assert/strict';
import { test } from 'node:test';
import os from 'node:os';
import type { CancellableCommandRunner } from '../src/collectors/exec.ts';
import type { FontFile, FontLookup } from '../src/fontFiles.ts';
import { silentLogger } from '../src/log.ts';
import type { PlistValue } from '../src/plist.ts';
import { CONSOLE_FONT_NAMES, machineProfileReaders, TerminalProfiles, terminalProfileReaders } from '../src/terminalProfiles.ts';
import { TERMINAL_FONT_PATH } from '../src/terminalProtocol.ts';

/** The signal of a daemon, and a page, that stay while the profile is read. */
const STAYING = new AbortController().signal;
const GUID = 'B1C2D3E4-0000-4000-8000-000000000138';
const ITERM_FONT = 'FiraCodeNF-Retina';
const ITERM_FILE: FontFile = { path: '/Users/owner/Library/Fonts/FiraCodeNerdFont-Retina.ttf', contentType: 'font/ttf' };
const CONSOLE_FILE: FontFile = { path: '/Library/Fonts/JetBrainsMonoNerdFont-Regular.otf', contentType: 'font/otf' };

/** iTerm's preferences with one default profile in `font` at 15 points, its foreground #cc3366. */
function itermPreferences(font: string = ITERM_FONT): PlistValue {
  return {
    'Default Bookmark Guid': GUID,
    'New Bookmarks': [{ Guid: GUID, 'Normal Font': `${font} 15`, 'Foreground Color': { 'Red Component': 0.8, 'Green Component': 0.2, 'Blue Component': 0.4, 'Color Space': 'sRGB' } }],
  };
}

/** The machine's font folders as a lookup: the first wanted name that is installed wins. */
function machineWith(installed: Record<string, FontFile>): FontLookup {
  return async (postScriptNames) => {
    for (const name of postScriptNames) if (installed[name] !== undefined) return installed[name];
    return null;
  };
}

const consoleFontInstalled = { [CONSOLE_FONT_NAMES[0]]: CONSOLE_FILE };
const bothFontsInstalled = { [ITERM_FONT]: ITERM_FILE, [CONSOLE_FONT_NAMES[0]]: CONSOLE_FILE };

function profiles(preferences: PlistValue | null, installed: Record<string, FontFile>): TerminalProfiles {
  return new TerminalProfiles({ readItermPreferences: async () => preferences, findFont: machineWith(installed) }, silentLogger, STAYING);
}

test('NoIterm_NoItermLook', async () => {
  assert.equal((await profiles(null, consoleFontInstalled).profile(STAYING)).iterm, null, 'because without iTerm the pane keeps the console\'s own theme');
});

test('NoIterm_ConsoleFontServed', async () => {
  assert.deepEqual(await profiles(null, bothFontsInstalled).font(STAYING), CONSOLE_FILE, 'because without iTerm the console serves its own Nerd Font, not some other installed font');
});

test('ItermProfile_ItsLookGiven', async () => {
  const look = (await profiles(itermPreferences(), bothFontsInstalled).profile(STAYING)).iterm;
  assert.deepEqual({ fontSize: look?.fontSize, foreground: look?.colours.foreground }, { fontSize: 15, foreground: '#cc3366' }, 'because with iTerm the pane takes its default profile\'s size and colours');
});

test('ItermProfile_ItsOwnFontServedBeforeTheConsoles', async () => {
  assert.deepEqual(await profiles(itermPreferences(), bothFontsInstalled).font(STAYING), ITERM_FILE, 'because the profile\'s font file is the one the console serves');
});

test('ItermFontNotInstalled_ConsoleFontServed', async () => {
  assert.deepEqual(await profiles(itermPreferences(), consoleFontInstalled).font(STAYING), CONSOLE_FILE, 'because a profile font that is not in the font folders falls back to the console\'s font');
});

test('ItermFontNotInstalled_ItermColoursKept', async () => {
  const look = (await profiles(itermPreferences(), consoleFontInstalled).profile(STAYING)).iterm;
  assert.equal(look?.colours.foreground ?? 'no iTerm look', '#cc3366', 'because a missing font file does not undo the colours the profile read');
});

test('ItermPreferencesWithoutADefaultProfile_NoItermLook', async () => {
  assert.equal((await profiles({ 'New Bookmarks': [] }, bothFontsInstalled).profile(STAYING)).iterm, null, 'because preferences that hold no default profile are an unreadable profile, and the console keeps its theme');
});

test('ItermPreferencesWithoutADefaultProfile_ConsoleFontServed', async () => {
  assert.deepEqual(await profiles({ 'New Bookmarks': [] }, bothFontsInstalled).font(STAYING), CONSOLE_FILE, 'because an unreadable profile names no font, so the console serves its own');
});

test('FontFound_ProfileNamesTheFontRouteNotTheFile', async () => {
  assert.deepEqual((await profiles(itermPreferences(), bothFontsInstalled).profile(STAYING)).font, { path: TERMINAL_FONT_PATH },
    'because the page fetches the font from the daemon\'s fixed route and never learns or names a file path');
});

test('NoFontInstalled_ProfileNamesNoFont', async () => {
  assert.equal((await profiles(itermPreferences(), {}).profile(STAYING)).font, null, 'because with no font to serve the page keeps its installed fonts');
});

test('NoFontInstalled_NoFontFile', async () => {
  assert.equal(await profiles(null, {}).font(STAYING), null, 'because nothing found is nothing served');
});

test('ProfileAskedTwice_ReadOnce', async () => {
  let reads = 0;
  const terminal = new TerminalProfiles({ readItermPreferences: async () => (reads++ === 0 ? itermPreferences() : null), findFont: machineWith(bothFontsInstalled) }, silentLogger, STAYING);
  await terminal.profile(STAYING);
  assert.notEqual((await terminal.profile(STAYING)).iterm, null, 'because the profile is read once at the first ask and kept, so later panes get the same look');
});

/**
 * `defaults` as a fake: the read verbs print iTerm's preferences as XML; any verb that changes
 * them throws, because reading the profile must never write to iTerm's settings.
 */
function readOnlyDefaults(xml: string, code = 0): CancellableCommandRunner {
  return async (request) => {
    const [verb] = request.args;
    if (verb !== 'export' && verb !== 'read') throw new Error(`defaults ${request.args.join(' ')} would change iTerm's settings`);
    return { code, stdout: xml, stderr: '', timedOut: false };
  };
}

const ITERM_XML = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Default Bookmark Guid</key>
	<string>${GUID}</string>
	<key>New Bookmarks</key>
	<array>
		<dict>
			<key>Guid</key>
			<string>${GUID}</string>
			<key>Normal Font</key>
			<string>${ITERM_FONT} 15</string>
		</dict>
	</array>
</dict>
</plist>
`;

test('MachineReaders_ItermInstalled_ItsPreferencesReadWithoutWriting', async () => {
  const read = await machineProfileReaders(readOnlyDefaults(ITERM_XML), os.tmpdir()).readItermPreferences(STAYING);
  assert.deepEqual(read, { 'Default Bookmark Guid': GUID, 'New Bookmarks': [{ Guid: GUID, 'Normal Font': `${ITERM_FONT} 15` }] },
    'because the preferences come from a read of iTerm\'s domain, parsed from its XML');
});

test('MachineReaders_DefaultsFails_NoPreferences', async () => {
  assert.equal(await machineProfileReaders(readOnlyDefaults('', 1), os.tmpdir()).readItermPreferences(STAYING), null, 'because a failed read is no iTerm, and the console keeps its look');
});

test('ConsoleLook_ItermInstalled_NoItermLookAndNoFont', async () => {
  const terminal = new TerminalProfiles(terminalProfileReaders('console', readOnlyDefaults(ITERM_XML), os.tmpdir()), silentLogger, STAYING);
  assert.deepEqual(await terminal.profile(STAYING), { iterm: null, font: null }, 'because a daemon under test reads neither iTerm\'s preferences nor the fonts');
});

test('MachineLook_ItermInstalled_ItsPreferencesRead', async () => {
  const preferences = await terminalProfileReaders('machine', readOnlyDefaults(ITERM_XML), os.tmpdir()).readItermPreferences(STAYING);
  assert.notEqual(preferences, null, "because the owner's console reads iTerm's preferences");
});

const unreadable = async (): Promise<never> => { throw new Error('defaults crashed mid-read'); };

test('ItermPreferencesThrow_NoItermLook', async () => {
  const terminal = new TerminalProfiles({ readItermPreferences: unreadable, findFont: machineWith(bothFontsInstalled) }, silentLogger, STAYING);
  assert.equal((await terminal.profile(STAYING)).iterm, null, 'because an unreadable profile leaves the pane on the console\'s own theme');
});

test('ItermPreferencesThrow_ConsoleFontServed', async () => {
  const terminal = new TerminalProfiles({ readItermPreferences: unreadable, findFont: machineWith(bothFontsInstalled) }, silentLogger, STAYING);
  assert.deepEqual(await terminal.font(STAYING), CONSOLE_FILE, 'because an unreadable profile still gets the console\'s own Nerd Font served');
});

test('PreferencesAndFontLookupBothThrow_ProfileNamesNoFont', async () => {
  const terminal = new TerminalProfiles({ readItermPreferences: unreadable, findFont: unreadable }, silentLogger, STAYING);
  assert.deepEqual(await terminal.profile(STAYING), { iterm: null, font: null }, 'because when nothing can be read the page keeps its own look, and the profile still answers');
});

test('PreferencesAndFontLookupBothThrow_NoFontFile', async () => {
  const terminal = new TerminalProfiles({ readItermPreferences: unreadable, findFont: unreadable }, silentLogger, STAYING);
  assert.equal(await terminal.font(STAYING), null, 'because a font lookup that fails serves nothing instead of failing the route');
});

test('ItermPreferencesThrewOnce_AskedAgain_SameFallbackNotARejection', async () => {
  let reads = 0;
  const terminal = new TerminalProfiles({
    readItermPreferences: async () => { reads += 1; if (reads === 1) throw new Error('defaults crashed mid-read'); return itermPreferences(); },
    findFont: machineWith(bothFontsInstalled),
  }, silentLogger, STAYING);
  await terminal.profile(STAYING);
  assert.deepEqual(await terminal.profile(STAYING), { iterm: null, font: { path: TERMINAL_FONT_PATH } }, 'because the kept answer after a failed read is the fallback, so a later ask neither rejects nor rereads');
});

/** A read of iTerm's preferences that waits until the test lets it finish. */
function heldPreferences(): { readItermPreferences: () => Promise<PlistValue | null>; finish: () => void } {
  let finish = (): void => undefined;
  const finished = new Promise<PlistValue | null>((resolve) => { finish = () => resolve(itermPreferences()); });
  return { readItermPreferences: () => finished, finish };
}

test('AskCancelledWhileTheProfileIsRead_ThatAskGetsTheConsoleLook', async () => {
  const held = heldPreferences();
  const terminal = new TerminalProfiles({ readItermPreferences: held.readItermPreferences, findFont: machineWith(bothFontsInstalled) }, silentLogger, STAYING);
  const pageLeft = new AbortController();
  const asked = terminal.profile(pageLeft.signal);
  pageLeft.abort();
  assert.deepEqual(await asked, { iterm: null, font: null }, 'because a page that left stops waiting on the read at once, and nothing it waited for is served');
});

test('AskCancelledWhileTheProfileIsRead_LaterAskGetsItermsLook', async () => {
  const held = heldPreferences();
  const terminal = new TerminalProfiles({ readItermPreferences: held.readItermPreferences, findFont: machineWith(bothFontsInstalled) }, silentLogger, STAYING);
  const pageLeft = new AbortController();
  const cancelled = terminal.profile(pageLeft.signal);
  pageLeft.abort();
  await cancelled;
  held.finish();
  assert.notEqual((await terminal.profile(STAYING)).iterm, null, 'because one page leaving cancels only its own wait, not the read every later pane shares');
});

test('DaemonStopsWhileTheProfileIsRead_ReadCancelledToTheConsoleLook', async () => {
  const daemonStopping = new AbortController();
  const terminal = new TerminalProfiles({
    readItermPreferences: (signal) => new Promise((resolve) => signal.addEventListener('abort', () => resolve(null), { once: true })),
    findFont: async (_names, signal) => (signal.aborted ? null : CONSOLE_FILE),
  }, silentLogger, daemonStopping.signal);
  const asked = terminal.profile(STAYING);
  daemonStopping.abort();
  assert.deepEqual(await asked, { iterm: null, font: null }, 'because the daemon\'s stop cancels both the preference read and the font search, so the read settles instead of outliving the daemon');
});
