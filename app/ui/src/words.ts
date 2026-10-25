/** The console's words, as the README's glossary says them, for tooltips and legends. */
export const WORDS = {
  dirty: 'The worktree has files that are not committed.',
  agents: 'Unattended claude or codex runs the flow started (claude -p, codex exec) working in this folder.',
  sessions: 'Interactive claude or codex someone is typing into (you, or an app such as the Claude desktop app), with its working directory here. Not an agent.',
  outside: 'Not in the pool: the main checkout, or another worktree git knows of. The flow never claims or releases these.',
  disagreement: 'Two places flow state lives say different things. A row shows only once both stores were read again and still disagree, so a store that merely lags never shows here.',
  projects: 'Projects are set when the daemon starts (--project); a Settings screen comes later.',
} as const;

/** What each gate asks of you, in one sentence; the flow's own help says the same. */
export const GATE_KINDS: Record<string, string> = {
  interview: 'The agent has interviewed you for a spec; confirm its recap.',
  'plan-approval': 'The agent wrote a plan; read it, then approve it or send it back.',
  decomposition: 'The agent wants to split the item; check the new items, their sizes and blockers.',
  'feel-test': 'The change is built; launch it and say how it feels.',
  merge: 'The pull request is ready; merge it on the host and the next job clears the gate.',
  escalation: 'A step failed three times; say what the agent should do.',
  ambiguity: 'The agent needs a decision only you can make; give it.',
};
