bump: minor

- A cleared gate's answer is never dropped in silence (#157). `gate.sh clear` records what carries
  the answer out in the new state key `answer_pending`: `next` when the item's step is one next
  runs, or `comments` when the item is at `done` with an open PR. The clear says which, so it no
  longer tells the owner to run `next` on a done item. An answer no step acts on (an item at
  `done` with no PR, or with a merged or closed one) fails with exit 1 and keeps the gate: "no
  step acts on this answer", do it by hand, then clear the gate with no answer. A send-back to
  `done` fails the same way. The merge gate, a clear with no answer and a decomposition gate that
  lets a split stand carry nothing out.
- The comments job names a waiting answer in the pass's brief ("The owner answered the <gate>
  gate: ..."), always gives it a pass, and takes it when the pass completes. The comments skill
  gains an Answer step: it carries the answer out on the PR's branch, or raises an escalation gate
  when the answer asks for work elsewhere, such as merging main into the PR's base. Before, a gate
  a comments pass raised on a done item was cleared and nothing read the answer.
- `next.sh` takes the answer when it starts the step whose brief carries it. On a done item whose
  answer waits on the comments job, it says so instead of "merge or close it".
- The board shows a waiting answer in the gate column (`none, answer waits on the comments job`),
  and in Health once it has waited past `jobs.health.gate_reminder`.
- Adapters: `answer_pending` is a new state key on github, jira and local.
