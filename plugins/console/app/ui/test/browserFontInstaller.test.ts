import { afterEach, expect, test, vi } from 'vitest';
import { browserFontInstaller } from '../src/xterm.ts';

const FAMILY = 'Served Pane Mono';
const FONT_BYTES = new Uint8Array([0x00, 0x01, 0x00, 0x00, 0x13, 0x8f]).buffer;

/** A face the browser built from a family and its bytes. */
type BuiltFace = { family: string; source: ArrayBuffer };

/** The browser's font boundary: `FontFace` loads or refuses its bytes, `document.fonts` keeps what the page added. */
function browserWithFonts(loads: boolean): { added: BuiltFace[] } {
  const added: BuiltFace[] = [];
  class StubFontFace implements BuiltFace {
    readonly family: string;
    readonly source: ArrayBuffer;
    constructor(family: string, source: ArrayBuffer) {
      this.family = family;
      this.source = source;
    }
    async load(): Promise<this> {
      if (!loads) throw new DOMException('the bytes are not a font', 'NetworkError');
      return this;
    }
  }
  vi.stubGlobal('FontFace', StubFontFace);
  Object.defineProperty(document, 'fonts', { configurable: true, value: { add: (face: BuiltFace) => { added.push(face); } } });
  return { added };
}

afterEach(() => {
  vi.unstubAllGlobals();
  Reflect.deleteProperty(document, 'fonts');
});

test('ServedFontLoads_JoinsThePagesFontsUnderTheServedFamily', async () => {
  const browser = browserWithFonts(true);
  await browserFontInstaller(FAMILY, FONT_BYTES);
  expect(browser.added.map((face) => ({ family: face.family, source: face.source })), 'because the terminal asks for the served family, so the served bytes must be in the page\'s fonts under that name').toEqual([{ family: FAMILY, source: FONT_BYTES }]);
});

test('ServedFontLoads_ReportsInstalled', async () => {
  browserWithFonts(true);
  expect(await browserFontInstaller(FAMILY, FONT_BYTES), 'because a loaded face lets the pane ask for the served font first').toBe(true);
});

test('ServedFontFailsToLoad_ReportsNotInstalled', async () => {
  browserWithFonts(false);
  expect(await browserFontInstaller(FAMILY, FONT_BYTES), 'because bytes the browser cannot load must leave the pane on the console\'s own font, not fail the page').toBe(false);
});

test('ServedFontFailsToLoad_NothingJoinsThePagesFonts', async () => {
  const browser = browserWithFonts(false);
  await browserFontInstaller(FAMILY, FONT_BYTES);
  expect(browser.added, 'because a face that did not load would draw nothing, so the page keeps only fonts that work').toEqual([]);
});
