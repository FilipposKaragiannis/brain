bump: minor

- The review step fails on a surviving Spec P1, an acceptance line the diff must carry and
  meets in part or not at all, and sends the item back to implement. A line the verify step or
  the feel test proves later is pending, not unmet. A PR-body note no longer meets a line; only
  the owner drops one, in the item. The quick depth refutes Spec P1s as well as P0s.
- The reproduce step pins the reported symptom from the item's Problem steps, never a lead
  alone, and measures the source when the item names several suspects. It now runs through
  `flow:test`, which has the epic-plan-reviewer review the diagnosis before the fix.
- The epic-plan-reviewer reads M task plans as well as L ones, and checks in the tracker each
  item a plan leans on: a closed prerequisite is met when its work is in the code, and a closed
  item the plan still expects work from is a Blocker.
