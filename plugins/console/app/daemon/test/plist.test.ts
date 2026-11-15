import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parsePlistXml } from '../src/plist.ts';

/** A document as `defaults export … -` writes one: the XML header, the DOCTYPE, then one value. */
function document(body: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n${body}\n</plist>\n`;
}

test('PlistXml_EveryKindItermExports_ReadAsTheirValues', () => {
  const xml = document(`<dict>
	<key>Name</key>
	<string>Work</string>
	<key>Columns</key>
	<integer>117</integer>
	<key>Red Component</key>
	<real>0.83</real>
	<key>Blinking Cursor</key>
	<true/>
	<key>Use Bright Bold</key>
	<false/>
	<key>Tags</key>
	<array>
		<string>first</string>
		<integer>-3</integer>
	</array>
	<key>Nested</key>
	<dict>
		<key>Inner</key>
		<string>deep</string>
	</dict>
</dict>`);
  assert.deepEqual(parsePlistXml(xml), {
    Name: 'Work', Columns: 117, 'Red Component': 0.83, 'Blinking Cursor': true, 'Use Bright Bold': false,
    Tags: ['first', -3], Nested: { Inner: 'deep' },
  }, 'because every kind iTerm writes must come back as the value it holds, nested as written');
});

test('PlistXml_EmptyElements_ReadAsEmptyValues', () => {
  const xml = document('<dict><key>Bookmarks</key><array/><key>Window</key><dict/><key>Title</key><string/></dict>');
  assert.deepEqual(parsePlistXml(xml), { Bookmarks: [], Window: {}, Title: '' }, 'because a self-closed array, dict or string is an empty one, not a missing value');
});

test('PlistXml_EscapedText_Decoded', () => {
  const xml = document('<dict><key>R&amp;D &lt;tab&gt;</key><string>&#x41;&#66; &quot;q&quot; &apos;s&apos;</string></dict>');
  assert.deepEqual(parsePlistXml(xml), { 'R&D <tab>': 'AB "q" \'s\'' }, 'because keys and strings carry XML entities and character references that stand for their characters');
});

test('PlistXml_InfiniteReals_ReadAsInfinities', () => {
  const xml = document('<array><real>+infinity</real><real>-infinity</real></array>');
  assert.deepEqual(parsePlistXml(xml), [Infinity, -Infinity], 'because iTerm\'s real preferences hold infinite reals, and one must not drop the whole file');
});

test('PlistXml_DataBesideADate_ParsesWithTheDateAsText', () => {
  const xml = document('<dict><key>Blob</key><data>\n\tAAEC\n\t</data><key>When</key><date>2026-11-15T09:30:00Z</date></dict>');
  const parsed = parsePlistXml(xml) as Record<string, unknown>;
  assert.equal(parsed.When, '2026-11-15T09:30:00Z', 'because a date the profile does not use must still parse, as its text');
});

test('PlistXml_MalformedText_Null', () => {
  const malformed: Record<string, string> = {
    unclosedDict: document('<dict><key>Name</key><string>Work</string>'),
    keyWithoutValue: document('<dict><key>Name</key></dict>'),
    noPlistElement: '<dict><key>Name</key><string>Work</string></dict>',
    notXml: 'Domain com.googlecode.iterm2 does not exist',
    empty: '',
  };
  for (const [shape, xml] of Object.entries(malformed)) {
    assert.equal(parsePlistXml(xml), null, `because ${shape} is not a property list, and the reader answers null rather than throwing or guessing`);
  }
});
