bump: minor

- A plan can name the proof for each acceptance line the user sees, in an `## Acceptance` section:
  the numbered line, then `Proof: evidence/<name>.png by <capture>`. Verify grades that line live
  from the file whatever the verifier wrote, and its `plan proofs` check fails verify, naming the
  file or the plan line, when the file is missing or empty, the `Proof:` line is malformed or its
  line is not in `proofs.json`. A plan that names no proof verifies as before. The planner,
  verifier and plan reviewer say so.
