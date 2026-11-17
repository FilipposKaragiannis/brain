import assert from 'node:assert/strict';
import { test } from 'node:test';
import { defaultItermProfile } from '../src/itermProfile.ts';
import type { ItermProfile } from '../src/itermProfile.ts';
import type { PlistDictionary } from '../src/plist.ts';

const DEFAULT_GUID = '6A2C1F0E-0B7D-4E1A-9C55-3D2E8F1B7A42';
const OTHER_GUID = 'F00D0000-1111-2222-3333-444455556666';

type Components = { red: number; green: number; blue: number; alpha?: number; space?: string | undefined };

/** A colour as iTerm stores it: components 0 to 1, and the space they are in when it names one. */
function colour(components: Components): PlistDictionary {
  const stored: Record<string, string | number> = { 'Red Component': components.red, 'Green Component': components.green, 'Blue Component': components.blue };
  if (components.alpha !== undefined) stored['Alpha Component'] = components.alpha;
  if (components.space !== undefined) stored['Color Space'] = components.space;
  return stored;
}

/** iTerm's preferences with these profiles, the one with `defaultGuid` its default. */
function preferences(profiles: PlistDictionary[], defaultGuid: string = DEFAULT_GUID): PlistDictionary {
  return { 'Default Bookmark Guid': defaultGuid, 'New Bookmarks': profiles };
}

/** The default profile read from preferences holding only `settings` as its profile. */
function readDefault(settings: PlistDictionary): ItermProfile {
  const profile = defaultItermProfile(preferences([{ Guid: DEFAULT_GUID, ...settings }]));
  assert.ok(profile !== null, 'because the preferences hold a default profile');
  return profile;
}

test('DefaultProfile_NotTheFirstBookmark_TheOneWhoseGuidIsTheDefault', () => {
  const profile = defaultItermProfile(preferences([
    { Guid: OTHER_GUID, 'Normal Font': 'Menlo-Regular 11' },
    { Guid: DEFAULT_GUID, 'Normal Font': 'JetBrainsMonoNF-Regular 14' },
  ]));
  assert.equal(profile?.fontName ?? 'no profile', 'JetBrainsMonoNF-Regular', 'because the pane takes the profile iTerm marks as default, wherever it sits in the list');
});

test('Preferences_WithoutADefaultProfile_NoProfile', () => {
  const shapes: Record<string, PlistDictionary> = {
    defaultGuidMatchesNoBookmark: preferences([{ Guid: OTHER_GUID }]),
    noBookmarks: { 'Default Bookmark Guid': DEFAULT_GUID },
    emptyPreferences: {},
  };
  for (const [shape, read] of Object.entries(shapes)) {
    assert.equal(defaultItermProfile(read), null, `because ${shape} names no profile to take, so the console keeps its own look`);
  }
});

test('NormalFont_NameAndSize_ReadApart', () => {
  const profile = readDefault({ 'Normal Font': 'JetBrainsMonoNFM-Regular 13' });
  assert.deepEqual({ fontName: profile.fontName, fontSize: profile.look.fontSize }, { fontName: 'JetBrainsMonoNFM-Regular', fontSize: 13 }, 'because "Normal Font" is the PostScript name, a space, then the size');
});

test('NormalFont_FractionalSize_Kept', () => {
  assert.equal(readDefault({ 'Normal Font': 'Menlo-Regular 12.5' }).look.fontSize, 12.5, 'because iTerm allows half points and the pane takes the size as is');
});

test('NoNormalFont_NoFontNameAndNoSize', () => {
  const profile = readDefault({});
  assert.deepEqual({ fontName: profile.fontName, fontSize: profile.look.fontSize }, { fontName: null, fontSize: null }, 'because a profile that names no font leaves the console\'s font and size');
});

test('SrgbColours_EveryColourTheProfileSets_MappedByName', () => {
  const settings: Record<string, PlistDictionary> = {};
  const expected: Record<string, string> = {};
  const keys: Record<string, string> = {
    'Ansi 0 Color': 'black', 'Ansi 1 Color': 'red', 'Ansi 2 Color': 'green', 'Ansi 3 Color': 'yellow',
    'Ansi 4 Color': 'blue', 'Ansi 5 Color': 'magenta', 'Ansi 6 Color': 'cyan', 'Ansi 7 Color': 'white',
    'Ansi 8 Color': 'brightBlack', 'Ansi 9 Color': 'brightRed', 'Ansi 10 Color': 'brightGreen', 'Ansi 11 Color': 'brightYellow',
    'Ansi 12 Color': 'brightBlue', 'Ansi 13 Color': 'brightMagenta', 'Ansi 14 Color': 'brightCyan', 'Ansi 15 Color': 'brightWhite',
    'Foreground Color': 'foreground', 'Background Color': 'background', 'Cursor Color': 'cursor', 'Cursor Text Color': 'cursorAccent',
    'Selection Color': 'selectionBackground', 'Selected Text Color': 'selectionForeground',
  };
  Object.entries(keys).forEach(([key, name], index) => {
    const redByte = (index + 1) * 10;
    settings[key] = colour({ red: redByte / 255, green: 51 / 255, blue: 102 / 255, space: 'sRGB' });
    expected[name] = `#${redByte.toString(16).padStart(2, '0')}3366`;
  });
  assert.deepEqual(readDefault(settings).look.colours, expected, 'because each iTerm colour lands on the xterm colour of the same role');
});

test('SrgbOrCalibratedOrUnnamedSpace_MappedStraightToHex', () => {
  for (const space of ['sRGB', 'Calibrated', undefined]) {
    const profile = readDefault({ 'Foreground Color': colour({ red: 0.8, green: 0.2, blue: 0.4, space }) });
    assert.equal(profile.look.colours.foreground, '#cc3366', `because a colour in ${space ?? 'no named'} space is taken as sRGB, its components straight to bytes`);
  }
});

test('P3Colour_ConvertedToSrgb', () => {
  // P3 (0.8, 0.3, 0.2) through the CSS Color 4 matrices is sRGB (221.0, 63.8, 37.3); read as sRGB it would be #cc4d33.
  const profile = readDefault({ 'Ansi 1 Color': colour({ red: 0.8, green: 0.3, blue: 0.2, space: 'P3' }) });
  assert.equal(profile.look.colours.red, '#dd4025', 'because a P3 colour must show in the page as the colour iTerm shows, not its components read as sRGB');
});

test('P3Grey_StaysTheSameGrey', () => {
  const profile = readDefault({ 'Background Color': colour({ red: 0.4, green: 0.4, blue: 0.4, space: 'P3' }) });
  assert.equal(profile.look.colours.background, '#666666', 'because P3 and sRGB share their white point and transfer curve, so a grey does not move');
});

test('P3PrimaryOutsideSrgb_ClampedToTheEdge', () => {
  const profile = readDefault({ 'Ansi 9 Color': colour({ red: 1, green: 0, blue: 0, space: 'P3' }) });
  assert.equal(profile.look.colours.brightRed, '#ff0000', 'because P3 red lies outside sRGB and each channel clamps to 0..255 rather than wrapping');
});

test('TranslucentColour_CarriesItsAlphaByte', () => {
  const profile = readDefault({ 'Selection Color': colour({ red: 0.8, green: 0.2, blue: 0.4, alpha: 0.6, space: 'sRGB' }) });
  assert.equal(profile.look.colours.selectionBackground, '#cc336699', 'because a colour below full alpha keeps its alpha as a fourth byte');
});

test('CursorType_MappedToItsShape', () => {
  const shapes: [number | undefined, string][] = [[0, 'underline'], [1, 'bar'], [2, 'block'], [undefined, 'block']];
  for (const [cursorType, shape] of shapes) {
    const settings: PlistDictionary = cursorType === undefined ? {} : { 'Cursor Type': cursorType };
    assert.equal(readDefault(settings).look.cursorStyle, shape, `because iTerm's cursor type ${cursorType ?? 'unset'} draws a ${shape}`);
  }
});

test('BlinkingCursor_Followed', () => {
  for (const blinking of [true, false]) {
    assert.equal(readDefault({ 'Blinking Cursor': blinking }).look.cursorBlink, blinking, `because the pane's cursor blinks exactly when iTerm's does (${blinking})`);
  }
});

test('UseBrightBold_Followed', () => {
  const rows: [boolean | undefined, boolean][] = [[true, true], [false, false], [undefined, true]];
  for (const [setting, bright] of rows) {
    const settings: PlistDictionary = setting === undefined ? {} : { 'Use Bright Bold': setting };
    assert.equal(readDefault(settings).look.boldIsBright, bright, `because "Use Bright Bold" ${setting ?? 'unset'} means bold draws ${bright ? 'bright' : 'in its own colour'}, as iTerm draws it`);
  }
});

test('SeparateLightAndDarkColours_DarkVariantTaken', () => {
  const profile = readDefault({
    'Use Separate Colors for Light and Dark Mode': true,
    'Background Color': colour({ red: 0.8, green: 0.2, blue: 0.4, space: 'sRGB' }),
    'Background Color (Dark)': colour({ red: 0.2, green: 0.4, blue: 0.8, space: 'sRGB' }),
  });
  assert.equal(profile.look.colours.background, '#3366cc', 'because the pane is dark in both page themes, so it takes the dark mode colour');
});

test('OneSetOfColours_PlainKeyTakenOverAStaleDarkVariant', () => {
  const profile = readDefault({
    'Use Separate Colors for Light and Dark Mode': false,
    'Background Color': colour({ red: 0.8, green: 0.2, blue: 0.4, space: 'sRGB' }),
    'Background Color (Dark)': colour({ red: 0.2, green: 0.4, blue: 0.8, space: 'sRGB' }),
  });
  assert.equal(profile.look.colours.background, '#cc3366', 'because with one set of colours iTerm draws the plain key and ignores the dark one');
});

test('SelectedTextColourTurnedOff_LeftOut', () => {
  const profile = readDefault({ 'Use Selected Text Color': false, 'Selected Text Color': colour({ red: 0.8, green: 0.2, blue: 0.4, space: 'sRGB' }) });
  assert.equal(profile.look.colours.selectionForeground, undefined, 'because iTerm keeps the text\'s own colour in a selection when the setting is off');
});

test('SelectedTextColourSettingMissing_ColourUsed', () => {
  const profile = readDefault({ 'Selected Text Color': colour({ red: 0.8, green: 0.2, blue: 0.4, space: 'sRGB' }) });
  assert.equal(profile.look.colours.selectionForeground, '#cc3366', 'because a profile that never turned the setting off uses its selected text colour');
});
