"""The playbooks on the brain map: four real sessions, step by step, with the command to type.
Hand-written, because they are a teaching order and not a listing. tools/test.sh (meta tests)
checks that every skill and agent named here exists, so a rename cannot leave a stale example.

A step is a dict:
  cmd   (plugin:skill, args)  what you type; Claude shows /plugin:skill args, Codex shows $skill args
  act   text           something you do outside the session (merge a PR, answer in chat)
  say   text           what happens, in one line
  who   [agents]       the agents that run it, in order
  out   text           what you get back
  stop  (gate, ask)    where the run stops and what it wants from you
"""

PLAYBOOKS = [
    {
        "id": "epic",
        "line": "epic",
        "title": "A new epic, from nothing",
        "lede": "You have an idea that needs several PRs.",
        "steps": [
            {"cmd": ("flow:new", 'epic "Players rejoin after a disconnect"'),
             "say": "Files the epic with a problem and an outcome. No size, no tasks yet.",
             "out": "gh#310"},
            {"cmd": ("flow:next", "gh#310"),
             "say": "Interviews you one question at a time, each with its own recommended answer. Facts it reads from the code.",
             "who": ["interviewer"],
             "stop": ("interview", "Answer in the session. Confirm the recap.")},
            {"cmd": ("flow:gate", 'gh#310 "spec confirmed"'),
             "say": "Records your answer and opens the next step."},
            {"cmd": ("flow:next", "gh#310"),
             "say": "Writes the epic body, then splits it into thin vertical tasks with sizes and blockers.",
             "who": ["planner", "epic-plan-reviewer"],
             "stop": ("decomposition", "Read the task list. Say what to merge, split or reorder.")},
            {"cmd": ("flow:gate", 'gh#310 "approved, split T3 in two"'),
             "say": "Your change goes to the planner in the next run."},
            {"cmd": ("flow:next", "gh#310"),
             "say": "Creates the tasks as issues under the epic, blockers set.",
             "who": ["planner"],
             "out": "gh#311 to gh#318"},
            {"cmd": ("flow:board", "show the dependency graph of gh#310"),
             "say": "Waves, what can run in parallel, the critical path."},
            {"cmd": ("flow:next", "gh#310"),
             "say": "Later, when every task is merged: checks them all closed, runs the epic-level checks, closes the epic.",
             "who": ["verifier"]},
        ],
    },
    {
        "id": "github",
        "line": "task-M",
        "title": "Work the tasks of a GitHub epic",
        "lede": "The epic exists. Its tasks are issues.",
        "steps": [
            {"cmd": ("flow:board", ""),
             "say": "Which tasks are ready, which are blocked, which worktrees are free, which gates wait on you."},
            {"cmd": ("flow:next", "gh#312"),
             "say": "Takes a free worktree, explores, designs, writes plan.md in phases. Without a name it takes the first ready task in list order.",
             "who": ["explorer", "architect", "planner"],
             "stop": ("plan-approval", "Read plan.md. Approve it or send it back with the change.")},
            {"cmd": ("flow:gate", 'gh#312 "plan approved"'),
             "say": "Opens the build."},
            {"cmd": ("flow:next", "gh#312"),
             "say": "Builds phase by phase, writes tests from the acceptance lines, reviews, verifies, opens the PR. A failed review or verify goes back to build, three times at most.",
             "who": ["implementer", "test-writer", "verifier", "pr-creator"],
             "stop": ("merge", "Review the PR. Merge it on GitHub.")},
            {"cmd": ("flow:gate", 'gh#312 "merged"'),
             "say": "Closes the gate."},
            {"cmd": ("flow:steward", "release gh#312"),
             "say": "Frees the worktree for the next task. Refuses if anything is uncommitted."},
            {"cmd": ("flow:next", ""),
             "say": "The merge cleared blockers. The next ready task starts. Open a second session and run it again to work two tasks at once."},
            {"cmd": ("flow:comments", "gh#312"),
             "say": "When a reviewer comments: grades each thread, fixes the valid ones, replies.",
             "who": ["comment-addresser"]},
        ],
    },
    {
        "id": "local",
        "line": "task-L",
        "title": "A multi-step task in the local tracker",
        "lede": "No GitHub issue. The item is a file under .flow/items.",
        "steps": [
            {"cmd": ("flow:new", "an L task: bots aim ahead of the ball"),
             "say": "Files it in the tracker the config names for tasks. Local by default.",
             "out": "local:task/1"},
            {"cmd": ("flow:next", "local:task/1"),
             "say": "Explores the code, researches only what the repo cannot answer, designs, then plans in phases. Phases that would each be a PR become sub-items instead.",
             "who": ["explorer", "researcher", "architect", "planner", "epic-plan-reviewer"],
             "stop": ("plan-approval", "Read design.md and plan.md. Approve or send back.")},
            {"cmd": ("flow:gate", 'local:task/1 "plan approved"'),
             "say": "Opens the build."},
            {"cmd": ("flow:next", "local:task/1"),
             "say": "One implementer per phase. Independent phases run in parallel in temporary worktrees and rebase onto the task branch. Then tests, deep review, verify, a plain-language explainer with a quiz, a draft PR.",
             "who": ["implementer", "test-writer", "verifier", "pr-creator"],
             "stop": ("merge", "Answer the quiz on the PR. Merge it.")},
            {"cmd": ("flow:gate", 'local:task/1 "merged"'),
             "say": "Closes the gate."},
            {"cmd": ("flow:steward", "release local:task/1"),
             "say": "Frees the worktree. The task branch goes with it."},
        ],
    },
    {
        "id": "bug",
        "line": "bugfix",
        "title": "Triage and fix a bug",
        "lede": "Something is wrong today and you can show it.",
        "steps": [
            {"cmd": ("flow:new", 'bug "Bots stall at the net after a restart"'),
             "say": "Looks for an existing item first. A match becomes a comment. Otherwise it files the bug with the steps to see it.",
             "out": "gh#340"},
            {"cmd": ("flow:next", "gh#340"),
             "say": "Writes one failing test that pins the bug, runs it red, commits it. Then the fix, tests, quick review, verify, the PR.",
             "who": ["test-writer", "implementer", "verifier", "pr-creator"],
             "stop": ("merge", "Check the failing test now passes. Merge.")},
            {"cmd": ("flow:gate", 'gh#340 "merged"'),
             "say": "Closes the gate."},
            {"cmd": ("flow:steward", "release gh#340"),
             "say": "Frees the worktree."},
        ],
    },
]

EXTRAS = [
    {"cmd": ("flow:next", ""), "say": "Work the queue. Stops at the first gate."},
    {"cmd": ("flow:gate", ""), "say": "List the gates waiting on you."},
    {"cmd": ("flow:board", ""), "say": "Everything in flight on one screen."},
    {"cmd": ("craft:improve", ""), "say": "Find refactors worth an epic, as a report with diagrams."},
    {"cmd": ("standards:review", ""), "say": "Review a branch or PR without an item (standards)."},
    {"cmd": ("meta:retro", ""), "say": "Turn the flow's lessons into changes to rules and skills."},
]

# The same step in plain words, for the "Plain words" view: what you can say to the flow:do skill.
ASK = {
    "epic": ["File an epic: players rejoin after a disconnect", "Grill me on gh#310", "The spec is right, go on",
             "Write the epic and split it into tasks for gh#310", "Approved, but split T3 in two",
             "Create the tasks for gh#310", "Show me the dependency graph of gh#310", "Close out gh#310, every task is merged"],
    "github": ["What is ready, blocked and waiting?", "Start on gh#312", "Plan approved", "Build gh#312", "gh#312 is merged",
               "Free the worktree for gh#312", "Start the next ready task", "Address the review comments on gh#312"],
    "local": ["File an L task: bots aim ahead of the ball", "Start local:task/1", "Plan approved", "Build local:task/1",
              "local:task/1 is merged", "Free the worktree for local:task/1"],
    "bug": ["File a bug: bots stall at the net after a restart", "Fix gh#340", "gh#340 is merged", "Free the worktree for gh#340"],
}
for _pb in PLAYBOOKS:
    assert len(ASK[_pb["id"]]) == len(_pb["steps"]), _pb["id"]
    for _st, _ask in zip(_pb["steps"], ASK[_pb["id"]]):
        _st["ask"] = _ask
EXTRAS[:] = [dict(e, ask=a) for e, a in zip(EXTRAS, [
    "Work the queue", "What is waiting on me?", "What is going on?", "Find refactors worth an epic", "Review this branch", "Run a retro"])]
EXTRAS.insert(0, {"cmd": ("flow:help", ""), "say": "The manual: every skill, the lines, the gates.", "ask": "What can the flow do?"})
