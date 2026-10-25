/** Structured logging. One JSON line per event on stderr; tests pass a silent logger. */
export type LogFields = Record<string, string | number | boolean | null>;

export type Logger = {
  info(event: string, fields: LogFields): void;
  warn(event: string, fields: LogFields): void;
  error(event: string, fields: LogFields): void;
};

export function stderrLogger(clock: () => Date): Logger {
  const write = (level: string, event: string, fields: LogFields): void => {
    process.stderr.write(JSON.stringify({ at: clock().toISOString(), level, event, ...fields }) + '\n');
  };
  return {
    info: (event, fields) => write('info', event, fields),
    warn: (event, fields) => write('warn', event, fields),
    error: (event, fields) => write('error', event, fields),
  };
}

export const silentLogger: Logger = { info: () => {}, warn: () => {}, error: () => {} };
