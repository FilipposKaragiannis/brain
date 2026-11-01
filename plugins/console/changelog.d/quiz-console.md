bump: minor

- The quiz the flow's explain step writes is taken in the console. A gate whose item has a quiz
  (`<reports>/quiz.md`, read with the gates from the claimed worktree, the pool and the main
  worktree) shows a quiz panel on its Gates card, and so does the PR card of that item: Take the
  quiz opens the questions, Check my answers grades the letters on the page and runs the new
  `quiz.answer` action (`quiz.sh answer <item> 1b 2a 3c`, flow 1.28.0), which keeps the result as
  `<reports>/quiz.json` and marks the draft PR ready for review on a pass. The results mark each
  question, show the right choice for a wrong one with the question's Because line, and offer
  Take it again; a kept result shows its score with See results. A merge gate or a PR card on a
  draft with a quiz still to pass says that is what holds it. The snapshot is schema 7: a gate and
  a pull carry `quiz`.
