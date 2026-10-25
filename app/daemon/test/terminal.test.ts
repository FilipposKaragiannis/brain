import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { appleScriptString, installedTerminals, shellLine, shellQuote, terminalLaunch } from '../src/terminal.ts';

const HOSTILE = ["/Users/o/my project", "/tmp/it's", '/tmp/a"b', '/tmp/$(touch pwned)', '/tmp/`id`; rm -rf ~', '/tmp/back\\slash', "/tmp/'; echo out; '"];

/** What sh makes of a line: each word it would run, as printf hands them back. */
function wordsOf(line: string): string[] {
  return execFileSync('sh', ['-c', `printf '%s\\0' ${line}`], { encoding: 'utf8' }).split('\0').slice(0, -1);
}

/** An AppleScript string literal read back, as osascript reads it. */
function appleScriptValue(literal: string): string {
  return literal.slice(1, -1).replace(/\\(.)/g, '$1');
}

test('ShellQuote_HostilePath_ReadBackWhole', () => {
  for (const word of HOSTILE) assert.deepEqual(wordsOf(shellQuote(word)), [word], `because ${JSON.stringify(word)} must stay one word and run nothing`);
});

test('ShellLine_PathWithSpaceOrQuote_CannotBreakOut', () => {
  for (const folder of HOSTILE) {
    const line = shellLine(folder, ['tail', '-f', `${folder}/.flow/log/next.log`]);
    const words = wordsOf(line.replace(' && ', ' '));
    assert.deepEqual(words, ['cd', folder, 'tail', '-f', `${folder}/.flow/log/next.log`], `because ${JSON.stringify(folder)} must reach cd and tail as itself`);
  }
});

test('AppleScriptString_QuoteAndBackslash_ReadBackWhole', () => {
  for (const text of HOSTILE) assert.equal(appleScriptValue(appleScriptString(text)), text, `because ${JSON.stringify(text)} must not end the AppleScript string`);
});

test('TerminalLaunch_HostileFolderInTerminal_OneScriptThatRunsOnlyTail', () => {
  const folder = "/tmp/it's \"here\"";
  const launch = terminalLaunch('terminal', [], folder, ['tail', '-n', '200', '-f', `${folder}/.flow/log/next.log`]);
  assert.ok(launch.ok, 'because Terminal is chosen');
  if (!launch.ok) return;
  const script = launch.launch.args[1] ?? '';
  const literal = script.slice('tell application "Terminal" to do script '.length);
  const line = appleScriptValue(literal);
  assert.deepEqual(wordsOf(line.replace(' && ', ' ')), ['cd', folder, 'tail', '-n', '200', '-f', `${folder}/.flow/log/next.log`], 'because the line Terminal runs is cd and tail with the folder as one word each time');
});

test('InstalledTerminals_FirstChoiceFirst', () => {
  const present = new Set(['/Users/o/Applications/Ghostty.app', '/System/Applications/Utilities/Terminal.app']);
  assert.deepEqual(installedTerminals((file) => present.has(file), '/Users/o'), ['ghostty', 'terminal'], 'because iTerm comes first, then Ghostty, then Terminal, found in /Applications, ~/Applications or where macOS keeps Terminal');
});

test('InstalledTerminals_NoneThere_Empty', () => {
  assert.deepEqual(installedTerminals(() => false, '/Users/o'), [], 'because with no app found Open in Terminal must say so instead of guessing');
});
