---
type: llm
---
The fixture's .flow/lessons.jsonl holds exactly these four lines:

{"time":"2026-10-08T10:00:00Z","kind":"review-blocker","item":"gh#301","step":"review","rule":"N-06","text":"Magic number 0.9 in OrderPricer.Price; the discount rate is not named","host":"claude"}
{"time":"2026-10-09T09:10:00Z","kind":"review-blocker","item":"gh#304","step":"review","rule":"N-06","text":"Magic numbers 3 and 7 in RetryPolicy; attempt counts not named","host":"codex"}
{"time":"2026-10-09T16:00:00Z","kind":"escalation","item":"gh#305","step":"verify","rule":"","text":"Step verify failed 3 times. Last: gate determinism: replay mismatch at tick 1200 because the physics seed was read from the clock","host":"claude"}
{"time":"2026-10-10T11:00:00Z","kind":"review-blocker","item":"gh#306","step":"review","rule":"N-06","text":"Magic number 60 in SessionTimeout; seconds per minute not named","host":"claude"}

Every finding the retro reports (a "what happened" it proposes to act on) rests on these lines. It invents no finding they do not support, such as another item, rule breach, recurring failure or a problem it noticed outside the log. The design of a proposed change, the reasoning about rules that already exist, and setting a line aside as a one-off are not findings. Saying the session itself gave nothing to route is fine.
