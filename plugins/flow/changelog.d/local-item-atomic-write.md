bump: patch

- The local tracker writes an item whole: a run that lists the items while another run updates
  one no longer reads it empty. Two runs started together could fail the pick with "cannot read",
  and a worker could end without a step.
