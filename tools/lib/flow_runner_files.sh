# flow_runner_files.sh: sourced by the suites that start the Flow suite runner in a throwaway
# project, so each copies the same files the runner loads.

flow_runner_copy() {
  cp -- "$1"/flow_*.py "$1"/flow_*.json "$2"
}
