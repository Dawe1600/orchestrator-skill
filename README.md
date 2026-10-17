# orchestrator

[![skills.sh](https://skills.sh/b/olivieropinotti/orchestrator-skill)](https://skills.sh/olivieropinotti/orchestrator-skill)

A Claude Code skill that turns your main session into a dispatcher that never blocks.

Every task goes to a background subagent. The main session only plans, dispatches, tracks
and reports, so you can keep talking while 3-5 agents work. A small ledger file
(`.claude/orchestrator.md`) tracks every agent and survives context compaction.

## Install

```bash
npx skills add olivieropinotti/orchestrator-skill
```

Then type `/orchestrator` in Claude Code. Say "stop orchestrating" to turn it off.

## What it does

- Splits each message into independent tasks and dispatches them in parallel.
- Sends follow-ups to the agent already on that topic, so its context stays intact.
- Writes a full brief for every agent: goal, facts, files it owns, what it must not do,
  and what "done" means.
- Picks the model per task: Opus for judgment, Sonnet for tight, checkable tasks.
- Answers "status" from the ledger.

## Commands

- `status`: list every agent and its state
- `stop <name>` / `stop all`
- `redirect <name> to ...`

MIT licensed.
