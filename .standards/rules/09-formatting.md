# 7. Linting and formatting

- **L-01 Code to green.** [hard] Zero warnings in any file. Warnings are build errors. Style and usage analyzers run in the build, so unused usings and unused members fail it. Editor-only inspections are added as a tool only where the build cannot catch the rule. *Why:* a yellow file is a review-and-fix loop waiting to happen; keep the infrastructure simple.
- **L-02 Clean namespaces.** [hard] No unused usings, usings sorted with the platform namespace first, no global usings, namespace equals folder path. *Why:* a file's header tells the reader exactly what it depends on.
- **L-03 `.editorconfig` is the single source of truth for formatting.** [hard] One per repo, changed only by the owner. The formatter runs in a pre-commit hook and CI verifies no changes. Editor-specific keys are extras, never the rule. *Why:* a rule that lives in one person's editor is invisible to agents and CI.
