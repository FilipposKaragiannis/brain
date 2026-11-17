/** A word as POSIX sh reads it back whole, whatever quotes, spaces or `$` it holds. */
export function shellQuote(word: string): string {
  return `'${word.replaceAll("'", `'\\''`)}'`;
}

/** A word a person can read and type: plain when sh would read it back whole, else quoted. */
function typedWord(word: string): string {
  return /^[A-Za-z0-9_./:=@%+,-]+$/.test(word) ? word : shellQuote(word);
}

/** The resume command as the owner would type it, such as `claude --resume 8f3c…`. */
export function commandText(argv: string[]): string {
  return argv.map(typedWord).join(' ');
}
