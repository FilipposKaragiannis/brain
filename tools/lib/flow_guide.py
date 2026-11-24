"""The hand-written part of the Flows section on the brain map: what each station does, what each
diamond wants from you, the commands that drive a line and the runs that go on without you.
Hand-written, because it is a teaching order and not a listing. tools/test.sh (meta tests)
checks that every skill, agent and script a step names exists, so a rename cannot leave a stale example.

A step is a dict:
  command  (plugin:skill, arguments)  what you type; Claude shows /plugin:skill arguments, Codex $skill arguments
  shell    text           a shell command, in a terminal or a scheduler; {host} becomes claude or codex
  action   text           something you do outside the session (edit a config, set a field)
  says     text           what happens, in one line
  agents   [agents]       the agents that run it, in order
  result   text           what you get back
  ask      text           a command or shell step in plain words, what you can say to the flow:do skill
"""

STATIONS = {
    "reproduce": "Writes one failing test that pins the bug, runs it red and commits it. The fix comes after.",
    "design": "Takes a free worktree and explores the code. The researcher looks up only what the repo cannot answer. Then it designs the change.",
    "plan": "Writes plan.md in phases, and on an M or L task the epic-plan-reviewer checks it. Phases that would each be a PR become sub-items instead.",
    "implement": "Builds phase by phase, one implementer per phase. Independent phases run in parallel in temporary worktrees and rebase onto the task branch.",
    "test": "Writes the tests from the acceptance lines, not from the code.",
    "review": "Reviews the diff, deeper the bigger the line: quick on a bug, deep on an L task.",
    "verify": "Runs the build, the tests and the project's own checks.",
    "explain": "Writes a plain-language explainer with a quiz you pass in the console.",
    "pr": "Opens the PR, a draft while the quiz waits for you.",
    "grill": "Interviews you one question at a time, each with its own recommended answer. Facts it reads from the code.",
    "epic": "Writes the epic body.",
    "tasks": "Splits the epic into thin vertical tasks with sizes and blockers, and the epic-plan-reviewer checks the list. They are filed as items under it.",
    "closeout": "When every task is merged: checks them all closed, runs the epic-level checks, then opens the epic's PR or closes the epic.",
}

GATE_HINTS = {
    "interview": "Answer in the session.",
    "decomposition": "Say what to merge, split or reorder.",
    "plan-approval": "Read design.md and plan.md in the reports.",
    "merge": "Review the PR on GitHub. On a bug, check the failing test now passes. On an L task, pass the quiz in the console first.",
    "ambiguity": "They come numbered, each with a recommended answer. Answer each in a sentence, in the session or in a comment on the issue: /answer as recommended, but 2 is a lunge. The next scheduled run reads it, clears the gate and hands your words to the next step.",
}

DRIVE = [
    {"command": ("flow:new", 'bug "Bots stall at the net after a restart"'),
     "says": "Files a bug, a task or an epic in the tracker the config names, local files under .flow/items by default. A bug is matched against the open items first, and a match becomes a comment; otherwise it is filed with the steps to see it. An epic gets a problem and an outcome, no size and no tasks yet.",
     "result": "gh#340",
     "ask": "File a bug: bots stall at the net after a restart"},
    {"command": ("flow:board", ""),
     "says": "Which items are ready, which are blocked, which worktrees are free, which gates wait on you. For an epic, its dependency graph: waves, what can run in parallel, the critical path.",
     "ask": "What is ready, blocked and waiting?"},
    {"command": ("flow:next", "gh#340"),
     "says": "Runs the item along its line to the next diamond. Without an id it takes the first ready item in list order. Open a second session and run it again to work two items at once.",
     "ask": "Start on gh#340"},
    {"command": ("flow:gate", 'gh#340 "plan approved"'),
     "says": "Records your answer at the diamond; a change you ask for goes to the next step. flow:next goes on from there. Without arguments it lists the gates waiting on you.",
     "ask": "Plan approved"},
    {"command": ("flow:gate", 'gh#340 "merged"'),
     "says": "After you merge the PR: closes the gate. The merge clears the blockers of the tasks behind it.",
     "ask": "gh#340 is merged"},
    {"command": ("flow:steward", "release gh#340"),
     "says": "Frees the worktree for the next item, and the task branch with it. Refuses while anything is uncommitted.",
     "ask": "Free the worktree for gh#340"},
    {"command": ("flow:comments", "gh#340"),
     "says": "When a reviewer comments: grades each thread, fixes the valid ones, replies.",
     "agents": ["comment-addresser"],
     "ask": "Address the review comments on gh#340"},
]

RUNS = [{
    "title": "Work the backlog unattended",
    "lede": "The tasks are filed, grilled and sized. Agents work them while you are away.",
    "steps": [
        {"action": "In .flow/config.yaml: auto_gates.plan-approval: S,M and notify.idle: true",
         "says": "Small and medium plans pass on their own. Merge and every other gate still wait for you."},
        {"shell": ".flow/run-unattended.sh {host} --max-steps 15",
         "says": "One run by hand first. It takes the first ready task, claims a worktree and runs every step as a fresh process with that agent's model and effort.",
         "agents": ["explorer", "architect", "planner", "implementer", "test-writer", "verifier", "pr-creator"],
         "ask": "Start a one-off unattended run on the queue"},
        {"shell": "<repo>/.flow/jobs/next.sh {host} --max-steps 15 --workers 2",
         "says": "Schedule it every 30 minutes: a Claude Desktop scheduled task, or launchd. Each worker takes its own ready task and worktree, works it to the next gate and logs to .flow/log/next-<n>.log. The pool caps the workers. After your merge, the next scheduled run starts a task it unblocked.",
         "ask": "Run a repeating unattended flow every 30 minutes, two at a time"},
        {"action": "The queue runs dry.",
         "says": "notify.idle sends one notice, on the desktop and in Slack, then stays quiet until a run does work again."},
    ],
}, {
    "title": "From a playtest note to an issue",
    "lede": "You jot notes while you play. An agent files each one overnight.",
    "steps": [
        {"action": "In .flow/config.yaml: intake.notes: docs/notes.md, a file in the repo; jobs.permission_mode: auto",
         "says": "One bullet per note, sub-lines under it. Headings are hints at the kind and the area."},
        {"shell": ".flow/jobs/intake.sh {host} --batch 3",
         "says": "One run by hand first. Each note gets its own fresh session: it checks the open items and the code, then files a typed, sized item with a suggested priority, or names the item it duplicates.",
         "result": "gh#341 to gh#343; the three notes leave the file, which is committed and pushed",
         "ask": "File my next three notes"},
        {"shell": "<repo>/.flow/jobs/intake.sh {host}",
         "says": "Schedule it nightly: a Claude Desktop scheduled task, or launchd. The ledger in .flow/log stops a note being filed twice.",
         "ask": ""},
        {"action": "Set the Priority field on the new items.",
         "says": "The agent only suggests one. An item without a priority is never ready, so nothing starts before you look. Then the items join the queue in priority order, worked by hand with flow:next or on the unattended schedule."},
        {"action": "A note the agent could not turn into testable lines.",
         "says": "It waits at the ambiguity diamond with its questions."},
    ],
}]

EXTRAS = [
    {"command": ("flow:help", ""), "says": "The manual: every skill, the lines, the gates.", "ask": "What can the flow do?"},
    {"command": ("craft:improve", ""), "says": "Find refactors worth an epic, as a report with diagrams.", "ask": "Find refactors worth an epic"},
    {"command": ("standards:review", ""), "says": "Review a branch or PR without an item (standards).", "ask": "Review this branch"},
    {"command": ("meta:retro", ""), "says": "Turn the flow's lessons into changes to rules and skills.", "ask": "Run a retro"},
]
