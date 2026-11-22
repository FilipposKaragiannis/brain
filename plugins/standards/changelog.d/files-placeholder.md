bump: patch

- The formatter hook reads `{files}` through the same shared helper as flow's verify, so the two
  cannot drift. A `{files}` inside a quote inside another quote, which two shells would read,
  now fails the format check with its reason, since its names could not stay data.
