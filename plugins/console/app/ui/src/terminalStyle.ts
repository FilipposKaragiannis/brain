import type { ItermLook, TerminalColours, TerminalCursorStyle, TerminalProfile } from '../../daemon/src/terminalProtocol.ts';
import { TERMINAL_COLOUR_NAMES, TERMINAL_CURSOR_STYLES, TERMINAL_PROFILE_PATH } from '../../daemon/src/terminalProtocol.ts';
import type { Api } from './api.ts';

/** The family the daemon's font file is installed under in the page. */
export const SERVED_FONT_FAMILY = 'Brain Console Terminal';
/** The pane's font size without an iTerm profile that names one. */
export const PANE_FONT_SIZE_PIXELS = 12;

/** Installs the font file as a web font of the family and settles once it is loaded; false when the browser cannot load it. */
export type FontInstaller = (family: string, bytes: ArrayBuffer) => Promise<boolean>;

/** What the page learnt of the panes' look before the first pane opens: iTerm's, if any, and whether the served font is loaded. */
export type TerminalStyle = { iterm: ItermLook | null; servedFont: boolean };

/** The console's own look: the page's theme and its installed fonts. */
export const CONSOLE_STYLE: TerminalStyle = { iterm: null, servedFont: false };

/** The page's terminal look, as its stylesheet sets it for the current theme. */
export type PageLook = { colours: TerminalColours; fontFamily: string };

/** A pane's look as its terminal is built; `followsPage` when the page's light and dark themes recolour it. */
export type PaneLook = {
  colours: TerminalColours;
  fontFamily: string;
  fontSize: number;
  cursorStyle: TerminalCursorStyle;
  cursorBlink: boolean;
  boldIsBright: boolean;
  followsPage: boolean;
};

const HTTP_OK = 200;
const CSS_HEX_COLOUR = /^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i;

/**
 * Asks the daemon for the panes' profile and, when it serves a font, loads that font before it
 * settles, so a terminal opened after it measures its cells in the font it draws with. Anything
 * the daemon does not give leaves the console's own look.
 */
export async function loadTerminalStyle(api: Api, installFont: FontInstaller): Promise<TerminalStyle> {
  const response = await api.request(TERMINAL_PROFILE_PATH, 'GET', null);
  const profile = response.status === HTTP_OK ? parseTerminalProfile(response.body) : null;
  if (profile === null) return CONSOLE_STYLE;
  const servedFont = profile.font !== null && await installServedFont(api, profile.font.path, installFont);
  return { iterm: profile.iterm, servedFont };
}

async function installServedFont(api: Api, path: string, installFont: FontInstaller): Promise<boolean> {
  const bytes = await api.requestBytes(path);
  return bytes !== null && installFont(SERVED_FONT_FAMILY, bytes);
}

/**
 * The look a pane's terminal takes. With an iTerm profile: its colours over the page's, its font
 * size, cursor and bold, fixed whatever the page's theme. Without one: the page's theme, followed.
 * The served font comes first in the family either way, then the page's stack.
 */
export function paneLook(style: TerminalStyle, page: PageLook): PaneLook {
  const fontFamily = style.servedFont ? [`'${SERVED_FONT_FAMILY}'`, page.fontFamily].filter((family) => family !== '').join(', ') : page.fontFamily;
  if (style.iterm === null) {
    return { colours: page.colours, fontFamily, fontSize: PANE_FONT_SIZE_PIXELS, cursorStyle: 'block', cursorBlink: false, boldIsBright: true, followsPage: true };
  }
  const { colours, fontSize, cursorStyle, cursorBlink, boldIsBright } = style.iterm;
  return { colours: { ...page.colours, ...colours }, fontFamily, fontSize: fontSize ?? PANE_FONT_SIZE_PIXELS, cursorStyle, cursorBlink, boldIsBright, followsPage: false };
}

/** The daemon's answer as a `TerminalProfile` whose fields have the types it promises; null for anything else. An iTerm look that is not one reads as none. */
export function parseTerminalProfile(body: unknown): TerminalProfile | null {
  if (!isRecord(body) || !('iterm' in body) || !('font' in body)) return null;
  const font = isRecord(body.font) && typeof body.font.path === 'string' ? { path: body.font.path } : null;
  return { iterm: parseItermLook(body.iterm), font };
}

function parseItermLook(value: unknown): ItermLook | null {
  if (!isRecord(value)) return null;
  const { fontSize, colours, cursorStyle, cursorBlink, boldIsBright } = value;
  if (!isFontSize(fontSize) || !isCursorStyle(cursorStyle) || typeof cursorBlink !== 'boolean' || typeof boldIsBright !== 'boolean') return null;
  return { fontSize, colours: parseColours(colours), cursorStyle, cursorBlink, boldIsBright };
}

/** The colours with a known name and a CSS hex value; any other entry is left out. */
function parseColours(value: unknown): TerminalColours {
  const colours: TerminalColours = {};
  if (!isRecord(value)) return colours;
  for (const name of TERMINAL_COLOUR_NAMES) {
    const colour = value[name];
    if (typeof colour === 'string' && CSS_HEX_COLOUR.test(colour)) colours[name] = colour;
  }
  return colours;
}

function isFontSize(value: unknown): value is number | null {
  return value === null || (typeof value === 'number' && Number.isFinite(value) && value > 0);
}

function isCursorStyle(value: unknown): value is TerminalCursorStyle {
  return TERMINAL_CURSOR_STYLES.some((style) => style === value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
