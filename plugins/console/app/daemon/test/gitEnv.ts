/**
 * The environment for git in a test's own temporary repository: this process's environment
 * without the variables that point git at a repository. A git hook sets them (GIT_INDEX_FILE
 * during pre-commit), so a test run from a hook would otherwise aim its git at the wrong index.
 */
const REPOSITORY_VARIABLES = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_PREFIX', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY'];

export function gitEnvironment(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = { ...process.env };
  for (const name of REPOSITORY_VARIABLES) delete environment[name];
  return { ...environment, ...extra };
}
