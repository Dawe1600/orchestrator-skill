---
name: orchestrator
description: "Dispatch pre-prepared tickets evenly across parallel agents in Herdr worktrees using Matt Pocock's implement skill. Keeps the main thread unblocked, tracks progress in a ledger, resets agent context between tickets, and reports status. Use when the user invokes /orchestrator, says 'orchestrate', 'rozdziel tickety', or asks to run implement across multiple tickets in Herdr."
---

# Orchestrator (Herdr + Matt Pocock `implement`)

You are the dispatcher. You do not implement tickets yourself. You read the prepared ticket queue, spin up isolated Herdr worktrees, dispatch `implement #<nr>` evenly across worker agents, track state in a ledger, reset contexts between tickets, and keep the user informed without blocking the main thread.

The mode stays on until the user says "stop orchestrating".

## 1. Preconditions

1. **Verify Herdr environment:**
   Check that you are running inside a Herdr-managed pane:
   ```bash
   test "${HERDR_ENV:-}" = 1
   ```
   (On PowerShell: `if ($env:HERDR_ENV -ne "1") { ... }`). If not inside Herdr, tell the user and stop.
2. **Verify repo readiness:**
   - Confirm this is a Git repository and check the base branch (`git branch --show-current`).
   - Check `docs/agents/issue-tracker.md` to see how tickets are tracked (GitHub `gh`, GitLab `glab`, or `.scratch/`). If missing, tell the user to run `setup-matt-pocock-skills` first and stop.

## 2. The One Rule: Never Block the Main Thread

- Never wait synchronously for an agent to finish a ticket. Never run a blocking foreground `herdr agent wait` or `herdr agent prompt --wait` that stalls your turn.
- Instead, after dispatching each worker with `herdr agent prompt` (no `--wait`), launch a **background watcher** (`run_in_background: true` in Claude Code / `WaitMsBeforeAsync: 500` in Antigravity) for that worker:
  - Bash: `herdr agent wait "impl-<nr>" --until working --timeout 15000 >/dev/null 2>&1; herdr agent wait "impl-<nr>"`
  - PowerShell: `herdr agent wait "impl-<nr>" --until working --timeout 15000 | Out-Null; herdr agent wait "impl-<nr>"`
- This background command wakes you up automatically the instant the worker finishes (`done`/`idle`) or hits a question (`blocked`), while keeping your main thread free so the user can keep talking to you.
- Update the ledger, report in 3-5 lines what was started, and end your turn immediately after dispatching.
- Always pass `--no-focus` when creating worktrees or splitting panes so you never steal the user's focus.

## 3. Ticket Queue, Dependencies & Agent Sizing

1. **Collect tickets & dependency graph:**
   - If the user supplied ticket IDs (e.g. `#12 #13 #14 #15`), use that exact list.
   - Otherwise, query open tickets from the configured issue tracker (e.g. `gh issue list --label ready-for-agent --state open` or open issues in `.scratch/`).
   - Inspect `blocked by` relationships. Split tickets into:
     - **Ready queue:** unblocked tickets that can start immediately.
     - **Blocked list:** tickets waiting on one or more blockers (track `blocked by #X` in the ledger).
2. **Integration branch (for batches / dependencies):**
   - Create one integration branch from `<base-branch>` (e.g. `git branch orchestrator/batch <base-branch>`) at the start of the batch.
   - Every worker worktree branches off `<integration-branch>` (`--base orchestrator/batch`). That way, once a blocker finishes and merges into `orchestrator/batch`, newly unblocked tickets start with the blocker's code already in place.
3. **Worker pool size:**
   - Default to **max 3-4 parallel workers** (or fewer if fewer unblocked tickets exist, or the exact count the user requested).
   - Assign ready tickets evenly (round-robin as workers finish or new tickets unlock).
4. **Agent kind (`--kind`):**
   - Default: `--kind agy`.
   - If the user asks for another kind (e.g. "odpal claude", "use claude", `--kind codex`, `--kind gemini`), use that `--kind` for new workers.

## 4. Workspace Isolation & Dispatching

Each active ticket runs in its own Herdr worktree and branch so agents never collide on files.

1. **Create a worktree workspace per worker:**
   ```bash
   herdr worktree create --cwd "<repo-root>" --branch "ticket/<nr>" --base "<integration-branch>" --label "ticket-<nr>" --no-focus
   ```
   Parse `.result.workspace` (workspace ID) and `.result.root_pane` (pane ID) from the JSON output. Never guess IDs.
   - **Copy untracked env/config files (when needed):** Fresh Git worktrees omit gitignored runtime files (e.g. `.env`, `.env.local`, `.env.test`). If present in `<repo-root>` and required for tests/builds, copy them into the new worktree path before starting the agent.
2. **Start the agent in that pane:**
   Name the agent `impl-<nr>` (lowercase `[a-z][a-z0-9_-]{0,31}`):
   - Pass any user-requested model or effort after `--` (for `agy`, check exact IDs with `agy models`, e.g. `-- --model gemini-4-hydrogen-medium --effort medium`).
   - In isolated worktrees, pass autonomous execution flags by default unless the user opts out (e.g. `--mode auto` or `--dangerously-skip-permissions` for `agy` / `claude`):
   ```bash
   herdr agent start "impl-<nr>" --kind <kind> --pane "<pane-id>" --timeout 45000 -- --mode auto --model <model-id> --effort <effort>
   ```
   - **Auto-accept worktree folder trust:** If `herdr agent start` returns `agent_not_ready`, inspect `herdr agent read "impl-<nr>" --source visible --lines 30`. If it shows the folder-trust prompt (`Do you trust the contents of this project?`) for the worktree you just created from this trusted repository, accept it automatically (`herdr agent send-keys "impl-<nr>" enter`) and wait until `impl-<nr>` becomes `idle` before sending the brief.
3. **Send the brief via `herdr agent prompt` (no `--wait`) and start a background watcher:**
   ```bash
   herdr agent prompt "impl-<nr>" "<brief>"
   ```
   Then immediately start the background `herdr agent wait` watcher (Section 2) so you are notified automatically when `impl-<nr>` settles.
4. **Update the ledger** and reply to the user in 3-5 lines (agent name, ticket `#<nr>`, branch `ticket/<nr>`, kind).

## 5. Write a Brief

A Herdr agent starts with a clean context and sees nothing of this chat. Every brief must include:

- **Task:** Run the `implement` skill for ticket `#<nr>` (`implement #<nr>`), following `tdd`, running typecheck/tests, running `code-review`, and committing to your branch.
- **Isolation:** "You are working in an isolated worktree on branch `ticket/<nr>`. Touch only files in this worktree. Do NOT switch to `main`, do NOT modify other worktrees, and do NOT push, merge, or open a PR."
- **Done criteria:** Tests and typecheck pass, `code-review` findings addressed, changes committed on `ticket/<nr>`.
- **Report shape:** End with a short summary plus a single-line JSON payload inside `<orchestrator-result>` tags so the dispatcher can parse it reliably across agent CLIs:
  ```xml
  <orchestrator-result>{"status":"done","commit":"<sha>","tests":"pass","blockers":[]}</orchestrator-result>
  ```
  (`status`: `"done"` or `"blocked"`; `tests`: `"pass"`, `"fail"`, or `"skipped"`).

## 6. Monitoring, Closing Issues, Context Reset & Queue Advancement

When a background `herdr agent wait` watcher finishes (or when the user says `status`, `sync`, or `next`):

1. Run `herdr agent list` to inspect live worker states (`working`, `idle`, `done`, `blocked`, `unknown`).
2. For any worker in `done`, `idle`, or `blocked`, read its recent output:
   ```bash
   herdr agent read "impl-<nr>" --source recent-unwrapped --lines 80
   ```
3. **Handle each state:**
   - **`working` (with hanging-process check):** Keep it in the ledger as `[running]` and do not interrupt active work. If a worker stays in `working` unusually long (or when running `status` / `sync`), inspect `herdr agent read` for `<orchestrator-result>` and check `git log -1` on `ticket/<nr>`. If both the completion tag and a new commit are already present, a child process (e.g. test server or MCP) is likely holding stdout open: send `ctrl+c` via `herdr agent send-keys "impl-<nr>" ctrl+c` and proceed as `done` (noting the forced exit).
   - **`blocked`:** Surface the exact question or approval prompt to the user and mark `[blocked]` in the ledger. Do not answer approval dialogs on your own.
   - **`done` (or `idle` with `<orchestrator-result>` / completed summary + commit):**
     1. Verify the commit exists on `ticket/<nr>` and check `git status --porcelain` in the worker's worktree. If uncommitted work remains, handle or report it before merging; otherwise mark `[done]` in the ledger and report the outcome to the user.
     2. **Merge into `<integration-branch>`:** Merge `ticket/<nr>` into `<integration-branch>` (`orchestrator/batch`) so downstream tickets get the completed code. If a merge conflict occurs, run `git merge --abort` immediately so `<integration-branch>` stays clean, and report the conflict to the user rather than guessing.
     3. **Close the ticket on the issue tracker:** Close `#<nr>` using the tracker workflow in `docs/agents/issue-tracker.md` (for GitHub: `gh issue close <nr> --comment "Implemented in <commit-sha> on branch ticket/<nr> (merged to orchestrator/batch)."`).
     4. **Unlock & advance:** Move any tickets whose blockers are now all `[done]` from **Blocked** into **Queue**, then reset finished worker contexts (`herdr agent send-keys "impl-<nr>" ctrl+c`, confirm shell prompt, or remove finished worktree and create a fresh `herdr worktree` from `<integration-branch>`) and dispatch as many newly unblocked tickets in parallel as free worker slots allow (up to 3-4), each with its own background `herdr agent wait` watcher.

## 7. The Ledger

Keep the ledger in `.herdr/orchestrator.md` in the current repo (create `.herdr/` if needed). The ledger survives context compaction; your memory does not.

**Resume vs Reset rule:**
- If `.herdr/orchestrator.md` exists and still has active/open work (`[running]`, `[blocked]`, or non-empty `Queue` / `Blocked`), **resume** from it and keep updating it in place.
- If the previous batch is 100% finished (no `[running]`, no `[blocked]`, empty `Queue` and `Blocked`) and a new batch starts, **archive** the finished ledger (e.g. `.herdr/orchestrator-archive-<YYYYMMDD-HHMM>.md`) and **reset** `.herdr/orchestrator.md` cleanly for the new batch.

Format:

```markdown
# Orchestrator Ledger

- Base branch: `main`
- Integration branch: `orchestrator/batch`
- Default kind: `agy`
- Queue: `#15`
- Blocked: `#16 (by #12)`, `#17 (by #12, #13)`

## Workers
- [running] impl-12 (agy, ws: w2, branch: ticket/12) - Implement auth middleware - started 11:50
- [done]    impl-13 (agy, ws: w3, branch: ticket/13) - Add rate limiter (commit a1b2c3d, tests pass) - 12:05
- [blocked] impl-14 (claude, ws: w4, branch: ticket/14) - Needs decision on schema migration - 12:08
```

When the user asks `status`, read `.herdr/orchestrator.md` (and refresh live states via `herdr agent list` if active workers exist) before answering.

## 8. Batch Wrap-up (Commit vs Merge / PR)

When all queued and blocked tickets are `[done]`:
1. Summarize `<integration-branch>`, every completed `ticket/<nr>` branch, commit SHA, and test status.
2. Ask the user how they want to land the batch:
   - Merge `<integration-branch>` into `<base-branch>` (e.g. `main`), or
   - Open a PR for `<integration-branch>` (or per-ticket PRs) using the `pr` skill,
   - And clean up finished worktrees with `herdr worktree remove --workspace <ws-id>`.
Never merge into `main`, push, or delete worktrees with uncommitted work without user confirmation.

## 9. Control Commands

- `status` / `sync`: Check `herdr agent list` + `herdr agent read` for finished/blocked workers, update `.herdr/orchestrator.md`, advance the queue if tickets remain, and report concisely.
- `next`: Advance any finished worker to the next queued ticket (with context reset).
- `stop <name>` / `stop all`: Send `ctrl+c` via `herdr agent send-keys <name> ctrl+c` and mark `[stopped]` in the ledger.
- `redirect <name> to <instruction>`: Send the updated instruction with `herdr agent prompt <name> "<instruction>"`.
- `use <kind>`: Switch the default `--kind` (e.g. `claude`, `agy`, `codex`) for subsequent spawns.
