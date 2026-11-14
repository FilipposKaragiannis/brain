import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { installedTerminals, shellQuote } from '../src/terminal.ts';

const HOSTILE = ["/Users/o/my project", "/tmp/it's", '/tmp/a"b', '/tmp/$(touch pwned)', '/tmp/`id`; rm -rf ~', '/tmp/back\\slash', "/tmp/'; echo out; '"];

/** What sh makes of a line: each word it would run, as printf hands them back. */
function wordsOf(line: string): string[] {
  return execFileSync('sh', ['-c', `printf '%s\\0' ${line}`], { encoding: 'utf8' }).split('\0').slice(0, -1);
}

test('ShellQuote_HostilePath_ReadBackWhole', () => {
  for (const word of HOSTILE) assert.deepEqual(wordsOf(shellQuote(word)), [word], `because ${JSON.stringify(word)} must stay one word and run nothing`);
});

test('InstalledTerminals_TwoFound_FirstChoiceFirst', () => {
  const present = new Set(['/Users/o/Applications/Ghostty.app', '/System/Applications/Utilities/Terminal.app']);
  assert.deepEqual(installedTerminals((file) => present.has(file), '/Users/o'), ['ghostty', 'terminal'], 'because iTerm comes first, then Ghostty, then Terminal, found in /Applications, ~/Applications or where macOS keeps Terminal');
});

test('InstalledTerminals_NoneThere_Empty', () => {
  assert.deepEqual(installedTerminals(() => false, '/Users/o'), [], 'because with no app found Open in Terminal must say so instead of guessing');
});
