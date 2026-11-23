---
name: orchestrator
description: "Dispatch pre-prepared tickets evenly across parallel agents in Herdr worktrees using Matt Pocock's implement skill. Keeps the main thread unblocked, tracks progress in a ledger, merges finished tickets into an integration branch, and reports status. Use when the user invokes /orchestrator, says 'orchestrate', 'rozdziel tickety', or asks to run implement across multiple tickets in Herdr."
---

# Orchestrator (Herdr + Matt Pocock `implement`)

You are the dispatcher. You do not implement tickets yourself. You read the prepared ticket queue, spin up isolated Herdr worktrees, dispatch `implement #<nr>` across worker agents, merge finished work into the integration branch, track state in a ledger, and keep the user informed without blocking the main thread.

The mode stays on until the user says "stop orchestrating".

Commands below are Bash (Git Bash on Windows). Helper scripts live in `~/.claude/skills/orchestrator/scripts/` (`$S` below); run them from the repo. Without the scripts: `jq` may be missing (parse Herdr JSON with `grep -oE` or `node -e`), and capture Herdr output in a variable instead of piping it, since Herdr panics when the reader closes the pipe.

## 1. Preconditions

1. **Herdr:** `test "${HERDR_ENV:-}" = 1`. If not inside Herdr, tell the user and stop.
2. **Repo:** confirm a Git repo and note the base branch (`git branch --show-current`).
3. **Tracker:** read `docs/agents/issue-tracker.md` for how tickets and blockers are tracked. If missing, tell the user to run `setup-matt-pocock-skills` first and stop.

## 2. The One Rule: Never Block the Main Thread

- Dispatch without waiting (`dispatch.sh`, Section 4), then run the `watcher:` command it prints as a **background watcher** (`run_in_background: true`), one per worker.
- The watcher wakes you when the worker settles (`done`/`idle`) or asks something (`blocked`), while the user can keep talking to you.
- After dispatching: update the ledger, report in 3-5 lines, end your turn.
- Pass `--no-focus` when creating worktrees or panes.

## 3. Ticket Queue, Dependencies & Agent Sizing

1. **Tickets & dependency graph:**
   - Use the ticket IDs the user gave; for a spec, its child tickets; otherwise open `ready-for-agent` tickets.
   - Read blockers the way the **Blocking** section of `docs/agents/issue-tracker.md` describes (on GitHub these are native dependencies: `gh api repos/<owner>/<repo>/issues/<nr>/dependencies/blocked_by --jq '[.[].number]'`, not text in the body).
   - Split into **Ready queue** and **Blocked list** (`#X (by #A, #B)`). Dispatch blockers first when choosing among ready tickets.
2. **Integration branch:** `git branch orchestrator/batch <base-branch>` at batch start. Every worker branches off the current `orchestrator/batch`, so unblocked tickets start with their blockers' code.
3. **Pool size:** max 3-4 parallel workers, or the count the user names.
4. **Agent kind:** the kind, model and effort the user names; otherwise the ones recorded in the most recent `.herdr/orchestrator-archive-*.md`; otherwise `agy`. Record them in the ledger.

## 4. Dispatching

**One ticket = one worktree = one agent.** A worker is never reused for a second ticket; a fresh worktree off the current `orchestrator/batch` is the context reset.

1. **Dispatch** with `bash "$S/dispatch.sh" <nr> <kind> --spec <spec-nr> --notes "<notes>" -- <agent args>`. It creates the worktree `ticket/<nr>` off `orchestrator/batch`, copies `.env*`, starts agent `impl-<nr>`, accepts the folder-trust prompt, sends the brief from `brief.md` (Section 5) and prints `ws=… pane=… agent=… path=…` plus the watcher command. On failure it prints the error and the pane screen; anything other than folder trust (login, update, unknown dialog) is the user's to answer.
   - Agent args are autonomous flags plus model and effort: `--mode auto` for `agy`; `--permission-mode auto --model <model-id> --effort <effort>` for `claude` (`--dangerously-skip-permissions` is blocked by the auto-mode classifier).
2. **Watcher** from the printed line (Section 2).
3. **Ledger** + 3-5 line reply (agent, ticket, branch, kind).

## 5. The Brief

The worker sees nothing of this chat. `brief.md` carries the fixed parts: task (`implement #<nr>` with `tdd`, build/test, `mattpocock-skills:code-review`, commit), parent spec, isolation, shared files, done criteria and the `<orchestrator-result>` line with its fields (`status`, `commit`, `tests`, `review`, `manual`, `blockers`). Edit the template when the review skill or result format changes; pass `--template <file>` for a one-off brief.

`--notes` carries what only you know, in one paragraph:

- **Repo specifics** the worker would otherwise trip on: dependency install, lockfile noise it must not commit, commit-message rules from the user's CLAUDE.md.
- **Cross-ticket notes:** when this ticket consumes what parallel tickets produce (e.g. CSP hashes of inline scripts), say so and ask for values derived at build time rather than hardcoded.

## 6. Monitoring & Merging

When a watcher finishes (or the user says `status` / `sync`):

1. `herdr agent list`, then for settled workers `herdr agent read "impl-<nr>" --source recent-unwrapped --lines 50`.
   - In a `claude` pane, grey text in the `❯` input box after the worker finishes is a Claude Code prompt suggestion, not input from the user.
2. **`working` too long:** if `<orchestrator-result>` and a new commit are both present, a child process holds stdout: `herdr agent send-keys "impl-<nr>" ctrl+c` and treat as done.
3. **`blocked`:** surface the exact question to the user, mark `[blocked]`. Approval dialogs are the user's to answer.
4. **`done`:**
   1. Commit exists on `ticket/<nr>`, `git status --porcelain` in its worktree is empty.
   2. **Merge** with `bash "$S/merge.sh" <nr> "<scratchpad>/batch-merge"`. The merge worktree is one checkout of `orchestrator/batch`, created by the first call (the main repo keeps the base branch checked out). The script fast-forwards or merges, then runs the gate in the merge worktree: dependency install (first use, `package.json` changed), build and tests from `package.json` scripts, or `INSTALL_CMD`/`BUILD_CMD`/`TEST_CMD` when the repo differs (`""` skips a step; record overrides in the ledger). Exit 0 green with the sha, 2 conflict with the file list (merge left in progress), 3 red with the failing output.
   3. **Conflicts** (exit 2): resolve by kind, commit, then rerun `merge.sh` for the gate.
      - *Additive* (both sides append: list items, CSS blocks at file end, imports, copied-file lists): keep both.
      - *Semantic* (one side changes or removes what the other edits, e.g. a removed component reappears in the other branch): port the other side's change onto the new shape. When the right shape is unclear, `git merge --abort` and ask the user.
   4. **Red gate** (exit 3): fix in the merge worktree or report; the ticket stays open until green. Also re-check spec-level rules no single ticket owns (e.g. docs that went stale because two tickets together changed the picture).
   5. **Close** the ticket per the tracker doc (`gh issue close <nr> --comment "Implemented in <sha> on branch ticket/<nr> (merged to orchestrator/batch)."`). Stop the worker (`herdr agent send-keys "impl-<nr>" ctrl+c`).
   6. **Advance:** move tickets whose blockers are all `[done]` into the queue; dispatch into free slots (Section 4), each with its watcher.
5. Report per merged ticket: commit, test count, `review` value if not `skill`, and every `manual` item.

## 7. The Ledger

`.herdr/orchestrator.md` in the repo. It survives context compaction; your memory does not.

- Active work in it (`[running]`, `[blocked]`, non-empty Queue/Blocked) → **resume** in place.
- Previous batch fully done → **archive** to `.herdr/orchestrator-archive-<YYYYMMDD>-<name>.md` and start fresh.

```markdown
# Orchestrator Ledger

- Spec: #15
- Base branch: `v2`
- Integration branch: `orchestrator/batch`; merge worktree: <path>
- Kind: `claude` (claude-opus-5-5, effort low, --permission-mode auto), max 4
- Queue: `#21`
- Blocked: `#23 (by #18, #19)`

## Workers
- [running] impl-18 (ws: wX, ticket/18) - Ikony SVG
- [done]    impl-16 (ws: wV, ticket/16) - Treść bez JS (553f32d, 56/56, closed)
- [blocked] impl-14 (ws: w4, ticket/14) - Needs decision on schema migration

## Notes
- Manual checks collected from workers; conflicts resolved and how.
```

## 8. Batch Wrap-up

When every ticket is `[done]`:

1. Summarize: integration branch head, each ticket's commit, final test count, collected `manual` items, any `review` other than `skill`.
2. Ask how to land it: fast-forward/merge into the base branch, or a PR (`pr` skill). Ask whether to close the parent spec. Merging into `main`, pushing and deploying wait for the user's explicit yes.
3. **Clean up** after landing:
   1. Every `ticket-*` worktree and the merge worktree has an empty `git status --porcelain`.
   2. `herdr worktree remove --workspace <ws-id>` per ticket; `git worktree remove` for the merge worktree; `git worktree prune`.
   3. `git branch -d ticket/<nr>...` and `orchestrator/batch` (merged, so `-d` succeeds).
   4. Archive the ledger (Section 7).
   5. Dependency install in the main repo if the batch changed `package.json`.

## 9. Control Commands

- `status` / `sync`: Section 6, then a short report.
- `stop <name>` / `stop all`: `herdr agent send-keys <name> ctrl+c`, mark `[stopped]`.
- `redirect <name> to <instruction>`: `herdr agent prompt <name> "<instruction>"`.
- `use <kind>`: switch kind for subsequent spawns and record it in the ledger.
