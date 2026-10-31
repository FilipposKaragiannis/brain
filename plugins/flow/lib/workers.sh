# The workers of the scheduled next run, per host, from jobs.workers in .flow/config.yaml: a flow
# map on one line ({claude: 1, codex: 2}) or a block map, one host per line. Sourced after
# lib/flow.sh and lib/host.sh, by jobs/next.sh and scripts/jobs.sh.
# jobs_workers: one host:count line per host with workers, claude first, so worker numbers stay
# put while the map does; nothing when jobs.workers is unset. A host other than claude or codex,
# a count that is not a whole number, or a map that starts no worker exits 2, naming the line.
jobs_workers() {
  set -- "$(cfg jobs.workers)"
  for _jw in $(yaml_keys "$(config_file)" jobs.workers); do set -- "$@" "$_jw=$(cfg "jobs.workers.$_jw")"; done
  python3 -I "$FLOW_PLUGIN/scripts/_jobs.py" workers "$(host_cfg_where jobs.workers)" "$@"
}
