/** Signal 0 checks that the process exists and sends nothing. */
const EXISTENCE_CHECK = 0;

/** Whether a process with this pid exists; EPERM means it does, under another user. */
export function processAlive(pid: number): boolean {
  try {
    process.kill(pid, EXISTENCE_CHECK);
    return true;
  } catch (error) {
    return error instanceof Error && 'code' in error && error.code === 'EPERM';
  }
}
