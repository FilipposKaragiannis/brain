bump: patch

- `gate.sh raise` refuses a gate that is not in `profiles.json`, before it writes a record, a
  state, a comment or a notification; `advance.sh` stops the same way on a step result that
  names one.
- `notify.sh` hands the desktop notifier its title, subtitle and body as arguments, so quotes,
  backslashes and `$(...)` in a gate text or an item title show literally.
- The GitHub adapter's `write-state` passes each label to `gh issue edit` as one argument, so a
  label value with a space stays whole.
