bump: patch

- `write-a-skill` gives a user-invoked skill's eval a grader on a call the skill makes, not on
  the Skill tool: a typed `/plugin:name` command loads the skill without that call, so the
  Skill-tool grader could never pass.
