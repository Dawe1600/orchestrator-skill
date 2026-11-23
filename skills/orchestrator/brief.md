Run `implement #{nr}` (parent spec: {spec}). Work test-first with `tdd`, run the repo's build and test commands, then run the review skill `mattpocock-skills:code-review` and address its findings, then commit.

Isolation: you work in an isolated worktree on branch `ticket/{nr}`. Touch only this worktree. Stay off `main` and the base branch; pushing, merging, opening a PR, deploying and closing issues are the dispatcher's job.

Shared files: other workers implement other tickets in parallel. Change shared files (global CSS, base layout, docs checklists, config lists) minimally and locally.

Notes: {notes}

Done means: build and tests pass, review findings addressed, work committed on `ticket/{nr}`, `git status` clean.

Report: a short summary, then exactly one line:
<orchestrator-result>{"status":"done","commit":"<sha>","tests":"pass","review":"skill","manual":["<unchecked manual check>"],"blockers":[]}</orchestrator-result>
status: done|blocked; tests: pass|fail|skipped; review: skill (review skill ran) | self (you only read your own diff) | skipped; manual: checks left for a human (browser, post-deploy), [] if none; blockers: open questions when blocked.
