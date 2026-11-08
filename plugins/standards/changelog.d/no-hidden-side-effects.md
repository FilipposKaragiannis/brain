bump: minor

- New hard rule M-08 No hidden side effects: a method changes only what its name says. A method
  that decides, checks or computes returns its result and the caller assigns it; it writes
  through a parameter only when its name says it changes that argument. CS-13 says the same for
  C# `ref`. A method named for a decision had its `in` velocity turned `ref` and overwritten; the
  implementer copied the file's habit and four reviewers passed it, because no rule named it.
- The standards-reviewer brief checks every signature that now lets a method write an argument
  it only read before against M-08.
