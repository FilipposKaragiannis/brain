import type { PlistDictionary, PlistValue } from './plist.ts';
import { isPlistDictionary } from './plist.ts';
import type { ItermLook, TerminalColourName, TerminalColours, TerminalCursorStyle } from './terminalProtocol.ts';
import { TERMINAL_COLOUR_NAMES } from './terminalProtocol.ts';

/** iTerm's default profile: the look a pane takes, and the PostScript name of its font, null when it names none. */
export type ItermProfile = { look: ItermLook; fontName: string | null };

/** A colour's red, green and blue, each 0 to 1. */
export type RgbColour = { red: number; green: number; blue: number };

const PROFILES_KEY = 'New Bookmarks';
const DEFAULT_PROFILE_KEY = 'Default Bookmark Guid';
const PROFILE_ID_KEY = 'Guid';
const FONT_KEY = 'Normal Font';
const CURSOR_TYPE_KEY = 'Cursor Type';
const CURSOR_BLINK_KEY = 'Blinking Cursor';
const BOLD_IS_BRIGHT_KEY = 'Use Bright Bold';
const USE_SELECTED_TEXT_KEY = 'Use Selected Text Color';
const SEPARATE_MODES_KEY = 'Use Separate Colors for Light and Dark Mode';
/** The pane is dark in both page themes, so a profile with a colour per mode gives it the dark one. */
const DARK_MODE_SUFFIX = ' (Dark)';
const P3_SPACE = 'P3';
const OPAQUE = 1;
const BYTE_MAXIMUM = 255;
const HEXADECIMAL = 16;
const HEX_DIGITS = 2;
/** "JetBrainsMonoNF-Regular 13": the PostScript name, a space, the size in points. */
const FONT_SETTING = /^(.+) (\d+(?:\.\d+)?)$/;

const COLOUR_KEYS: Record<TerminalColourName, string> = {
  black: 'Ansi 0 Color', red: 'Ansi 1 Color', green: 'Ansi 2 Color', yellow: 'Ansi 3 Color',
  blue: 'Ansi 4 Color', magenta: 'Ansi 5 Color', cyan: 'Ansi 6 Color', white: 'Ansi 7 Color',
  brightBlack: 'Ansi 8 Color', brightRed: 'Ansi 9 Color', brightGreen: 'Ansi 10 Color', brightYellow: 'Ansi 11 Color',
  brightBlue: 'Ansi 12 Color', brightMagenta: 'Ansi 13 Color', brightCyan: 'Ansi 14 Color', brightWhite: 'Ansi 15 Color',
  foreground: 'Foreground Color', background: 'Background Color', cursor: 'Cursor Color', cursorAccent: 'Cursor Text Color',
  selectionBackground: 'Selection Color', selectionForeground: 'Selected Text Color',
};

/** iTerm's "Cursor Type" values. */
const CURSOR_TYPES: Record<number, TerminalCursorStyle> = { 0: 'underline', 1: 'bar', 2: 'block' };
const DEFAULT_CURSOR_STYLE: TerminalCursorStyle = 'block';

/** Display P3 linear light to CIE XYZ, from its primaries and the D65 white point (x 0.3127, y 0.3290). */
const DISPLAY_P3_TO_XYZ = [
  [0.48657094864821626, 0.26566769316909294, 0.1982172852343625],
  [0.22897456406974884, 0.6917385218365062, 0.079286914093745],
  [0, 0.045113381858902575, 1.0439443689009757],
] as const;
/** CIE XYZ to sRGB linear light, the inverse of sRGB's primaries on the same white point. */
const XYZ_TO_SRGB = [
  [3.2409699419045213, -1.5373831775700935, -0.4986107602930033],
  [-0.9692436362808798, 1.8759675015077206, 0.04155505740717561],
  [0.05563007969699361, -0.20397695888897657, 1.0569715142428786],
] as const;
/** The sRGB transfer curve, which Display P3 shares: a line near black, a 2.4 power above it. */
const TRANSFER_LINEAR_LIMIT_ENCODED = 0.04045;
const TRANSFER_LINEAR_LIMIT_LINEAR = 0.0031308;
const TRANSFER_LINEAR_SLOPE = 12.92;
const TRANSFER_OFFSET = 0.055;
const TRANSFER_SCALE = 1.055;
const TRANSFER_EXPONENT = 2.4;

/**
 * The default profile of iTerm's preferences: the "New Bookmarks" entry whose "Guid" is the
 * "Default Bookmark Guid". Null when the preferences hold no such profile.
 */
export function defaultItermProfile(preferences: PlistValue): ItermProfile | null {
  if (!isPlistDictionary(preferences)) return null;
  const defaultId = preferences[DEFAULT_PROFILE_KEY];
  const profiles = preferences[PROFILES_KEY];
  if (typeof defaultId !== 'string' || !Array.isArray(profiles)) return null;
  const profile = (profiles as readonly PlistValue[]).find((candidate) => isPlistDictionary(candidate) && candidate[PROFILE_ID_KEY] === defaultId);
  return isPlistDictionary(profile) ? itermProfile(profile) : null;
}

function itermProfile(profile: PlistDictionary): ItermProfile {
  const font = fontSetting(profile[FONT_KEY]);
  const look: ItermLook = {
    fontSize: font?.size ?? null,
    colours: profileColours(profile),
    cursorStyle: cursorStyle(profile[CURSOR_TYPE_KEY]),
    cursorBlink: profile[CURSOR_BLINK_KEY] === true,
    boldIsBright: profile[BOLD_IS_BRIGHT_KEY] !== false,
  };
  return { look, fontName: font?.name ?? null };
}

function fontSetting(value: PlistValue | undefined): { name: string; size: number | null } | null {
  if (typeof value !== 'string' || value.trim() === '') return null;
  const parts = FONT_SETTING.exec(value.trim());
  if (parts === null) return { name: value.trim(), size: null };
  return { name: parts[1]!, size: Number(parts[2]) };
}

function cursorStyle(value: PlistValue | undefined): TerminalCursorStyle {
  return typeof value === 'number' ? CURSOR_TYPES[value] ?? DEFAULT_CURSOR_STYLE : DEFAULT_CURSOR_STYLE;
}

/** The colours the profile sets, each read from its dark-mode key first when the profile keeps one per mode. */
function profileColours(profile: PlistDictionary): TerminalColours {
  const suffix = profile[SEPARATE_MODES_KEY] === true ? DARK_MODE_SUFFIX : '';
  const colours: TerminalColours = {};
  for (const name of TERMINAL_COLOUR_NAMES) {
    if (name === 'selectionForeground' && profile[USE_SELECTED_TEXT_KEY] === false) continue;
    const key = COLOUR_KEYS[name];
    const colour = cssColour(profile[`${key}${suffix}`] ?? profile[key]);
    if (colour !== null) colours[name] = colour;
  }
  return colours;
}

/** An iTerm colour as CSS: "P3" converted to sRGB, "sRGB", "Calibrated" or no space taken as sRGB. */
function cssColour(value: PlistValue | undefined): string | null {
  if (!isPlistDictionary(value)) return null;
  const { 'Red Component': red, 'Green Component': green, 'Blue Component': blue, 'Alpha Component': alpha } = value;
  if (typeof red !== 'number' || typeof green !== 'number' || typeof blue !== 'number') return null;
  const stored = { red, green, blue };
  const colour = value['Color Space'] === P3_SPACE ? displayP3ToSrgb(stored) : stored;
  const opacity = typeof alpha === 'number' ? alpha : OPAQUE;
  const channels = [colour.red, colour.green, colour.blue, ...(opacity < OPAQUE ? [opacity] : [])];
  return `#${channels.map(hexByte).join('')}`;
}

/** A Display P3 colour as the nearest sRGB one: to linear light, through XYZ, back to the curve, clamped to the sRGB gamut. */
export function displayP3ToSrgb(colour: RgbColour): RgbColour {
  const linear = [colour.red, colour.green, colour.blue].map(decodeTransfer);
  const [red, green, blue] = transform(XYZ_TO_SRGB, transform(DISPLAY_P3_TO_XYZ, linear)).map((channel) => encodeTransfer(clampUnit(channel)));
  return { red: red!, green: green!, blue: blue! };
}

function transform(matrix: readonly (readonly number[])[], vector: readonly number[]): number[] {
  return matrix.map((row) => row.reduce((sum, weight, column) => sum + weight * vector[column]!, 0));
}

function decodeTransfer(encoded: number): number {
  if (encoded <= TRANSFER_LINEAR_LIMIT_ENCODED) return encoded / TRANSFER_LINEAR_SLOPE;
  return ((encoded + TRANSFER_OFFSET) / TRANSFER_SCALE) ** TRANSFER_EXPONENT;
}

function encodeTransfer(linear: number): number {
  if (linear <= TRANSFER_LINEAR_LIMIT_LINEAR) return linear * TRANSFER_LINEAR_SLOPE;
  return TRANSFER_SCALE * linear ** (1 / TRANSFER_EXPONENT) - TRANSFER_OFFSET;
}

function clampUnit(channel: number): number {
  return Math.min(1, Math.max(0, channel));
}

function hexByte(channel: number): string {
  return Math.round(clampUnit(channel) * BYTE_MAXIMUM).toString(HEXADECIMAL).padStart(HEX_DIGITS, '0');
}
