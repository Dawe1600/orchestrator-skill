# orchestrator (Herdr + Matt Pocock `implement`)

Forked from [olivieropinotti/orchestrator-skill](https://github.com/olivieropinotti/orchestrator-skill) and adapted for **Herdr** (`herdr` CLI) and **Matt Pocock's engineering skills** (`implement`).

## What it does

- Turns the main session into a non-blocking dispatcher for pre-prepared tickets (GitHub/GitLab/local `.scratch/`).
- Isolates each parallel worker in its own `herdr worktree` (`ticket/<nr>` branch) off a shared integration branch (`orchestrator/batch`).
- Respects `blocked by` dependencies: waits on blockers, merges finished blockers into `orchestrator/batch`, and dispatches newly unblocked tickets in parallel.
- Runs `implement #<nr>` on each worker (`tdd`, typecheck/tests, `code-review`, commit on its own branch).
- Uses `--kind agy` by default, or any supported Herdr agent kind (`claude`, `codex`, `gemini`, etc.) on request.
- Tracks active workers, branches, and queued tickets in `.herdr/orchestrator.md`.
- Resets agent context between tickets and asks before merging, pushing, or opening PRs (with `pr`).

## Install

Copy `skills/orchestrator/SKILL.md` into your global skills directory (for example `~/.gemini/config/skills/orchestrator/SKILL.md` or `~/.claude/skills/orchestrator/SKILL.md`), or install via `skills`:

```bash
npx skills add Dawe1600/orchestrator-skill
```

## Commands

- `status` / `sync`: refresh worker states from `herdr agent list`, update `.herdr/orchestrator.md`, and advance finished workers to the next queued ticket
- `next`: assign the next queued ticket to idle/finished workers (with fresh context)
- `use <kind>`: switch default `--kind` (e.g. `claude`, `agy`)
- `stop <name>` / `stop all`
- `redirect <name> to ...`

MIT licensed.
