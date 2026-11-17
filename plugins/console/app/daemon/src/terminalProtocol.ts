/**
 * The terminal pane's look, shared by the daemon and the page: the iTerm profile it takes and
 * the font file the daemon serves for it. No node imports, so the page imports this file as it
 * imports `paneProtocol.ts`.
 */

/** `GET` the `TerminalProfile` the panes take. */
export const TERMINAL_PROFILE_PATH = '/api/terminal/profile';
/** `GET` the font file the profile's `font` names; the daemon picks the file, the request names none. */
export const TERMINAL_FONT_PATH = '/api/terminal/font';

/** The colours a profile sets, by xterm's theme names: the 16 ANSI colours, then the screen's own. */
export const TERMINAL_COLOUR_NAMES = [
  'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite',
  'foreground', 'background', 'cursor', 'cursorAccent', 'selectionBackground', 'selectionForeground',
] as const;
export type TerminalColourName = (typeof TERMINAL_COLOUR_NAMES)[number];

/** CSS colours in sRGB (`#rrggbb`, or `#rrggbbaa` when not opaque), only those the profile sets. */
export type TerminalColours = { [name in TerminalColourName]?: string };

export const TERMINAL_CURSOR_STYLES = ['block', 'underline', 'bar'] as const;
export type TerminalCursorStyle = (typeof TERMINAL_CURSOR_STYLES)[number];

/** iTerm's default profile as a pane takes it; `fontSize` is in pixels, null when the profile names no font. */
export type ItermLook = {
  fontSize: number | null;
  colours: TerminalColours;
  cursorStyle: TerminalCursorStyle;
  cursorBlink: boolean;
  /** Bold text in the 8 normal colours draws in their bright colours. */
  boldIsBright: boolean;
};

/**
 * `iterm` is null without iTerm or when its default profile cannot be read. `font` is where the
 * daemon serves the profile's font file, or the console's own Nerd Font without one; null when
 * neither is in the machine's font folders.
 */
export type TerminalProfile = { iterm: ItermLook | null; font: { path: string } | null };
