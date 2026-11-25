bump: patch

- The PR body opens with the verify verdict, `Verdict: pass at <sha>`, and how many acceptance
  lines are proven live or by test. Then three sections, always in this order: Summary,
  Verification and Merge danger. The old Evidence and Review sections fold into Verification.
- Verification always has a Not checked list, which says "nothing" when every acceptance line
  is proven. The summary keeps one view, never several.
