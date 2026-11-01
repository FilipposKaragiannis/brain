bump: minor

- The quiz the explain step writes is taken in the console, not on the PR. `scripts/quiz.sh show
  <item>` prints `<reports>/quiz.md` as JSON (title, questions, choices, the answer key, each
  question's `Because:` line) with the last result; `quiz.sh answer <item> 1b 2a 3c` (or `b a c`
  in question order) grades it, writes `<reports>/quiz.json`, logs one `quiz` line in events.log
  and on a pass marks the item's draft PR ready (`comments.sh ready`) when it has one on GitHub.
  The console's Gates and Pull requests pages run it from a Take the quiz button and show the
  result with the justifications.
- `quiz.md` is multiple choice only, and every question carries a `Because:` line that says why
  the right choice is right; the explain skill checks the file with `quiz.sh show`. The pr-creator
  still opens a draft while a quiz exists but posts nothing of it on the PR; the comments pass no
  longer grades a comment, and marks a draft ready only when `quiz.json` says the quiz passed.
- The PR body's Merge danger section says what Door and Blast radius mean where they are read:
  Door is how hard the merge is to undo (two-way: a revert undoes it; one-way: it does not, and
  why), Blast radius is what is affected if the change is wrong, in a word or two.
