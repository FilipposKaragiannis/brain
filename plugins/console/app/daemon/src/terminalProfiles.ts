import type { CommandRunner } from './collectors/exec.ts';
import { scriptEnvironment } from './collectors/exec.ts';
import type { FontFile, FontLookup } from './fontFiles.ts';
import { folderFontLookup, macFontFolders } from './fontFiles.ts';
import type { ItermProfile } from './itermProfile.ts';
import { defaultItermProfile } from './itermProfile.ts';
import type { Logger } from './log.ts';
import { errorMessage } from './log.ts';
import type { PlistValue } from './plist.ts';
import { parsePlistXml } from './plist.ts';
import type { TerminalProfile } from './terminalProtocol.ts';
import { TERMINAL_FONT_PATH } from './terminalProtocol.ts';

/** What the profile is read from, injected so tests read no real preferences or font folders. */
export type TerminalProfileReaders = {
  /** iTerm's preferences; null when iTerm is not installed or they cannot be read. Never throws. */
  readItermPreferences: () => Promise<PlistValue | null>;
  findFont: FontLookup;
};

/**
 * The console's own font, served when iTerm names none or its font is not there: the
 * JetBrainsMono Nerd Font the page's stylesheet asks for, by PostScript name, in the same order.
 */
export const CONSOLE_FONT_NAMES = ['JetBrainsMonoNF-Regular', 'JetBrainsMonoNerdFont-Regular', 'JetBrainsMonoNFM-Regular', 'JetBrainsMonoNerdFontMono-Regular'] as const;

const DEFAULTS_COMMAND = '/usr/bin/defaults';
const ITERM_DOMAIN = 'com.googlecode.iterm2';
const DEFAULTS_TIMEOUT_MILLISECONDS = 10000;

type Resolved = { profile: TerminalProfile; font: FontFile | null };

const CONSOLE_LOOK_WITHOUT_FONT: Resolved = { profile: { iterm: null, font: null }, font: null };

/**
 * The look the terminal panes take: iTerm's default profile when there is one, and the font file
 * the daemon serves for it. Read once, on the first ask, and kept until the daemon stops. Never
 * rejects: when the profile cannot be read the panes keep the console's look and font.
 */
export class TerminalProfiles {
  private readonly readers: TerminalProfileReaders;
  private readonly log: Logger;
  private resolved: Promise<Resolved> | null = null;

  constructor(readers: TerminalProfileReaders, log: Logger) {
    this.readers = readers;
    this.log = log;
  }

  async profile(): Promise<TerminalProfile> {
    return (await this.resolve()).profile;
  }

  /** The font file the profile's `font` names; null when it names none. */
  async font(): Promise<FontFile | null> {
    return (await this.resolve()).font;
  }

  private resolve(): Promise<Resolved> {
    this.resolved ??= this.read();
    return this.resolved;
  }

  private async read(): Promise<Resolved> {
    try {
      const preferences = await this.readers.readItermPreferences();
      return await this.resolveFor(preferences === null ? null : defaultItermProfile(preferences));
    } catch (error) {
      this.log.warn('terminal.profile.unreadable', { error: errorMessage(error) });
      return this.resolveFor(null).catch((fontError: unknown) => {
        this.log.warn('terminal.font.unreadable', { error: errorMessage(fontError) });
        return CONSOLE_LOOK_WITHOUT_FONT;
      });
    }
  }

  private async resolveFor(iterm: ItermProfile | null): Promise<Resolved> {
    const fontName = iterm?.fontName ?? null;
    const font = await this.readers.findFont(fontName === null ? CONSOLE_FONT_NAMES : [fontName, ...CONSOLE_FONT_NAMES]);
    this.log.info('terminal.profile', { iterm: iterm !== null, font: font?.path ?? null });
    return { profile: { iterm: iterm?.look ?? null, font: font === null ? null : { path: TERMINAL_FONT_PATH } }, font };
  }
}

/** The readers on this machine: `defaults export` for iTerm's preferences (it only reads them), the macOS font folders for the font. */
export function machineProfileReaders(runner: CommandRunner, home: string): TerminalProfileReaders {
  return {
    readItermPreferences: async () => {
      const exported = await runner({ command: DEFAULTS_COMMAND, args: ['export', ITERM_DOMAIN, '-'], cwd: home, timeoutMs: DEFAULTS_TIMEOUT_MILLISECONDS, env: scriptEnvironment() });
      return exported.code === 0 ? parsePlistXml(exported.stdout) : null;
    },
    findFont: folderFontLookup(macFontFolders(home)),
  };
}
