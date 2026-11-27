bump: minor

- A plan can give an acceptance line the user sees a named proof, in an `## Acceptance` section:
  the numbered line, then `Proof: evidence/<name>.png by <capture>`. Verify grades a named proof
  live from its file whatever the verifier wrote, and its `plan proofs` check fails verify, naming
  the file or the plan line, when the file is missing or empty, the `Proof:` line is malformed or
  its line is not in `proofs.json`. A plan with no named proof verifies as before. The planner,
  verifier and plan reviewer say so.
