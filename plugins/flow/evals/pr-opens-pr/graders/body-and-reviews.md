---
type: llm
focus:
  source: file
  path: .fake-gh/issues.json
---
This is a fake GitHub's state. The "pr" object's "body" holds a summary of the change, the verify
results (build and tests passing) and the line `Item: local:task/1`, and it tags no reviewer with
an @. Review requests are separate comments, one per reviewer, either in the "pr" object's
"comments" or in the comments of issue 91.
