bump: patch

- `gate.sh raise` refuses a gate that is not in `profiles.json`, before it writes a record, a
  state, a comment or a notification; `advance.sh` stops the same way on a step result that
  names one.
- `notify.sh` hands the desktop notifier its title, subtitle and body as arguments, so quotes,
  backslashes and `$(...)` in a gate text or an item title show literally.
- The GitHub adapter's `write-state` passes each label to `gh issue edit` as one argument, so a
  label value with a space stays whole.
- The GitHub adapter's `write-state` refuses a label value with a comma, which `gh` would read as
  two labels, and leaves an existing label with a comma alone instead of passing it to
  `--remove-label`.
- `advance.sh` refuses an unknown gate on every path that raises one, the sync step included.
- Every gate the flow raises (interview, plan-approval, decomposition, feel-test, merge,
  escalation, ambiguity) is in `profiles.json`, so no caller needed a looser shape check.
