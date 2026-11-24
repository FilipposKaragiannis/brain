---
type: llm
focus:
  source: file
  path: .fake-gh/issues.json
---
This is a fake GitHub's state. The "pr" object's "body" opens with the verdict line
`Verdict: pass at <commit sha>`, then has three sections in this order and no others: Summary,
Verification and Merge danger. Verification holds the verify results (build and tests passing)
and a Not checked list. The body has the line `Item: local:task/1`, and it tags no reviewer with
an @. Review requests are separate comments, one per reviewer, either in the "pr" object's
"comments" or in the comments of issue 91.
