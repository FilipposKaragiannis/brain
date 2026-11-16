import { expect, test } from 'vitest';
import { TERMINAL_FONT_PATH, TERMINAL_PROFILE_PATH } from '../../daemon/src/terminalProtocol.ts';
import type { ItermLook, TerminalProfile } from '../../daemon/src/terminalProtocol.ts';
import { CONSOLE_STYLE, loadTerminalStyle, PANE_FONT_SIZE_PIXELS, paneLook, parseTerminalProfile, SERVED_FONT_FAMILY } from '../src/terminalStyle.ts';
import type { FontInstaller, PageLook } from '../src/terminalStyle.ts';
import { FakeDaemon, HTTP_OK } from './fakeDaemon.tsx';

const ITERM: ItermLook = {
  fontSize: 15,
  colours: { foreground: '#cc3366', background: '#0d1117', red: '#dd4025', selectionBackground: '#3366cc99' },
  cursorStyle: 'bar',
  cursorBlink: true,
  boldIsBright: false,
};
const PAGE: PageLook = { colours: { foreground: '#e6edf3', background: '#161b22', red: '#ff7b72', green: '#3fb950' }, fontFamily: '"Page Mono", monospace' };
const FONT_BYTES = new Uint8Array([0x00, 0x01, 0x00, 0x00, 0x13, 0x8f]).buffer;

/** The browser's font set as the page sees it: each family it loaded, with its bytes. */
function browserFonts(loads = true): { installer: FontInstaller; loaded: Map<string, ArrayBuffer> } {
  const loaded = new Map<string, ArrayBuffer>();
  return { loaded, installer: async (family, bytes) => { if (loads) loaded.set(family, bytes); return loads; } };
}

const STILL_LOADING = 'still loading';

/** The signal of a page that stays open while its look loads. */
const STAYING = new AbortController().signal;

/** Settles on the next task, after every pending microtask: a style that does not wait for the font has settled by then. */
function afterPendingWork<T>(value: T): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), 0));
}

/** A font the browser is still loading: `asked` settles once the page asks for it, `finish` ends the load. */
function slowFont(): { installer: FontInstaller; asked: Promise<void>; finish: (loaded: boolean) => void } {
  let askedNow: () => void = () => {};
  let finish: (loaded: boolean) => void = () => {};
  const asked = new Promise<void>((resolve) => { askedNow = resolve; });
  const load = new Promise<boolean>((resolve) => { finish = resolve; });
  return { installer: () => { askedNow(); return load; }, asked, finish: (loaded) => finish(loaded) };
}

function daemonServing(profile: TerminalProfile, fontBytes: ArrayBuffer | null = FONT_BYTES): FakeDaemon {
  const daemon = new FakeDaemon();
  daemon.answer('GET', TERMINAL_PROFILE_PATH, () => ({ status: HTTP_OK, body: profile }));
  if (fontBytes !== null) daemon.files.set(TERMINAL_FONT_PATH, fontBytes);
  return daemon;
}

test('ProfileUnusable_ConsoleStyle', async () => {
  const answers: [string, number, unknown][] = [['the daemon is unreachable', 0, { error: 'network error' }], ['the daemon fails', 500, { error: 'down' }], ['the body is not a profile', HTTP_OK, 'iterm'], ['the body is empty', HTTP_OK, null]];
  for (const [shape, status, body] of answers) {
    const daemon = new FakeDaemon();
    daemon.answer('GET', TERMINAL_PROFILE_PATH, () => ({ status, body }));
    expect(await loadTerminalStyle(daemon, browserFonts().installer, STAYING), `because when ${shape} the pane keeps the console's own theme and font`).toEqual(CONSOLE_STYLE);
  }
});

test('NoProfileRoute_ConsoleStyle', async () => {
  expect(await loadTerminalStyle(new FakeDaemon(), browserFonts().installer, STAYING), 'because an older daemon without the route must not break the pane').toEqual(CONSOLE_STYLE);
});

test('ServedFont_LoadedUnderTheServedFamily', async () => {
  const fonts = browserFonts();
  await loadTerminalStyle(daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }), fonts.installer, STAYING);
  expect(fonts.loaded.get(SERVED_FONT_FAMILY), 'because the page loads the daemon\'s font file itself, so a browser that hides installed fonts still draws its glyphs').toBe(FONT_BYTES);
});

test('ServedFontLoaded_StyleSaysSo', async () => {
  const style = await loadTerminalStyle(daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }), browserFonts().installer, STAYING);
  expect(style.servedFont, 'because a loaded served font is the one the pane asks for first').toBe(true);
});

test('ServedFontStillLoading_StyleNotReady', async () => {
  const font = slowFont();
  const loading = loadTerminalStyle(daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }), font.installer, STAYING);
  await font.asked;
  const first = await Promise.race([loading, afterPendingWork(STILL_LOADING)]);
  font.finish(true);
  await loading;
  expect(first, 'because the terminal measures its cells once the style is ready, so the style waits for the font to load').toBe(STILL_LOADING);
});

test('ServedFontFinishesLoading_StyleUsesIt', async () => {
  const font = slowFont();
  const loading = loadTerminalStyle(daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }), font.installer, STAYING);
  await font.asked;
  font.finish(true);
  expect((await loading).servedFont, 'because a font that finishes loading after the ask is still the one the pane asks for first').toBe(true);
});

test('ServedFontUnavailable_ConsoleFontKept', async () => {
  const rows: [string, FakeDaemon, FontInstaller][] = [
    ['the font bytes are missing', daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }, null), browserFonts().installer],
    ['the browser cannot load them', daemonServing({ iterm: null, font: { path: TERMINAL_FONT_PATH } }), browserFonts(false).installer],
    ['the profile names no font', daemonServing({ iterm: null, font: null }), browserFonts().installer],
  ];
  for (const [shape, daemon, installer] of rows) {
    expect((await loadTerminalStyle(daemon, installer, STAYING)).servedFont, `because when ${shape} the pane keeps the console's font and nothing fails`).toBe(false);
  }
});

test('CancelledBeforeTheProfileAnswers_ConsoleStyle', async () => {
  const pageLeft = new AbortController();
  pageLeft.abort();
  const style = await loadTerminalStyle(daemonServing({ iterm: ITERM, font: { path: TERMINAL_FONT_PATH } }), browserFonts().installer, pageLeft.signal);
  expect(style, 'because a cancelled load settles to the console\'s own look instead of throwing into the page').toEqual(CONSOLE_STYLE);
});

test('CancelledWhileTheFontLoads_ConsoleStyle', async () => {
  const pageLeft = new AbortController();
  const font = slowFont();
  const loading = loadTerminalStyle(daemonServing({ iterm: ITERM, font: { path: TERMINAL_FONT_PATH } }), font.installer, pageLeft.signal);
  await font.asked;
  pageLeft.abort();
  font.finish(true);
  expect(await loading, 'because a load cancelled midway settles to the console\'s own look, not half of the profile').toEqual(CONSOLE_STYLE);
});

test('ItermProfile_PassedToThePanes', async () => {
  const style = await loadTerminalStyle(daemonServing({ iterm: ITERM, font: { path: TERMINAL_FONT_PATH } }), browserFonts().installer, STAYING);
  expect(style.iterm, 'because the panes take iTerm\'s look as the daemon read it').toEqual(ITERM);
});

test('ItermFontUnavailable_ItermLookKept', async () => {
  const style = await loadTerminalStyle(daemonServing({ iterm: ITERM, font: { path: TERMINAL_FONT_PATH } }, null), browserFonts().installer, STAYING);
  expect(style.iterm, 'because a font that does not load leaves iTerm\'s colours in place').toEqual(ITERM);
});

test('MalformedItermLook_DroppedToNoIterm', () => {
  const malformed: Record<string, unknown> = {
    unknownCursorStyle: { ...ITERM, cursorStyle: 'beam' },
    blinkNotABoolean: { ...ITERM, cursorBlink: 'yes' },
    negativeFontSize: { ...ITERM, fontSize: -3 },
  };
  for (const [shape, iterm] of Object.entries(malformed)) {
    expect(parseTerminalProfile({ iterm, font: { path: TERMINAL_FONT_PATH } })?.iterm, `because a look with ${shape} is not iTerm's profile, so the console keeps its theme`).toBeNull();
  }
});

test('MalformedItermLook_FontKept', () => {
  const profile = parseTerminalProfile({ iterm: { ...ITERM, cursorStyle: 'beam' }, font: { path: TERMINAL_FONT_PATH } });
  expect(profile?.font, 'because a bad look does not stop the page loading the served font').toEqual({ path: TERMINAL_FONT_PATH });
});

test('BadColours_DroppedGoodOnesKept', () => {
  const colours = { foreground: '#cc3366', background: 'rgb(0, 0, 0)', red: '#abc', cursor: '#3366cc99', sparkle: '#ffffff', green: 7 };
  const profile = parseTerminalProfile({ iterm: { ...ITERM, colours }, font: null });
  expect(profile?.iterm?.colours, 'because only #rrggbb or #rrggbbaa colours of a known name reach xterm; the rest fall back to the page\'s').toEqual({ foreground: '#cc3366', cursor: '#3366cc99' });
});

test('NoIterm_PaneFollowsThePageTheme', () => {
  const look = paneLook(CONSOLE_STYLE, PAGE);
  expect({ colours: look.colours, followsPage: look.followsPage }, 'because without iTerm the pane takes the page\'s theme and recolours with it').toEqual({ colours: PAGE.colours, followsPage: true });
});

test('NoIterm_ConsoleFontSize', () => {
  expect(paneLook(CONSOLE_STYLE, PAGE).fontSize, 'because without iTerm the pane keeps the console\'s font size').toBe(PANE_FONT_SIZE_PIXELS);
});

test('Iterm_ItsColoursOverThePagesWithThePageFillingTheGaps', () => {
  expect(paneLook({ iterm: ITERM, servedFont: true }, PAGE).colours, 'because the pane takes every colour the profile sets and the page\'s for the rest')
    .toEqual({ foreground: '#cc3366', background: '#0d1117', red: '#dd4025', selectionBackground: '#3366cc99', green: '#3fb950' });
});

test('Iterm_PaneNoLongerFollowsThePageTheme', () => {
  expect(paneLook({ iterm: ITERM, servedFont: true }, PAGE).followsPage, 'because iTerm\'s profile is one look, kept when the page switches between light and dark').toBe(false);
});

test('Iterm_ItsSizeAndCursorTaken', () => {
  const look = paneLook({ iterm: ITERM, servedFont: true }, PAGE);
  expect({ fontSize: look.fontSize, cursorStyle: look.cursorStyle, cursorBlink: look.cursorBlink, boldIsBright: look.boldIsBright }, 'because the pane takes the profile\'s font size, cursor shape, blink and bold as is')
    .toEqual({ fontSize: 15, cursorStyle: 'bar', cursorBlink: true, boldIsBright: false });
});

test('ItermWithoutAFontSize_ConsoleFontSize', () => {
  expect(paneLook({ iterm: { ...ITERM, fontSize: null }, servedFont: true }, PAGE).fontSize, 'because a profile that names no font leaves the console\'s size').toBe(PANE_FONT_SIZE_PIXELS);
});

test('ServedFontLoaded_ItsFamilyAskedForBeforeThePageStack', () => {
  const family = paneLook({ iterm: null, servedFont: true }, PAGE).fontFamily;
  const servedAt = family.indexOf(SERVED_FONT_FAMILY);
  expect(servedAt >= 0 && servedAt < family.indexOf(PAGE.fontFamily), `because the served font draws the glyphs, with the page's stack behind it, in "${family}"`).toBe(true);
});

test('ServedFontNotLoaded_PageStackOnly', () => {
  expect(paneLook({ iterm: null, servedFont: false }, PAGE).fontFamily, 'because a family that never loaded would only delay the page\'s own fonts').toBe(PAGE.fontFamily);
});
