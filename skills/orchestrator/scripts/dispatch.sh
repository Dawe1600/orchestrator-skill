#!/usr/bin/env bash
# Dispatch one ticket: Herdr worktree + agent impl-<nr> + brief from template.
# Usage: dispatch.sh <nr> <kind> [--spec <nr>] [--notes <text>] [--template <file>] [--cwd <repo>] [-- <agent args>]
# Prints: ws=<id> pane=<id> agent=impl-<nr> path=<worktree>, then the watcher command.
# herdr output is always captured into variables (never piped), so a closed pipe cannot make it panic.
set -u
shopt -u patsub_replacement 2>/dev/null || true

die() { echo "dispatch: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: dispatch.sh <nr> <kind> [--spec N] [--notes TEXT] [--template FILE] [--cwd REPO] [-- agent args]"

nr=$1 kind=$2; shift 2
spec="" notes="" cwd="." template="$(cd "$(dirname "$0")/.." && pwd)/brief.md"
while [ $# -gt 0 ]; do
  case $1 in
    --spec) spec=$2; shift 2 ;;
    --notes) notes=$2; shift 2 ;;
    --template) template=$2; shift 2 ;;
    --cwd) cwd=$2; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -f "$template" ] || die "template not found: $template"
agent="impl-$nr"

root=$(git -C "$cwd" rev-parse --show-toplevel) || die "not a git repo: $cwd"
command -v cygpath >/dev/null && root_win=$(cygpath -w "$root") || root_win=$root

# JSON string field (first match), unescaped; no jq needed.
field() { printf '%s' "$2" | grep -oE "\"$1\":\"[^\"]*\"" | head -n1 | sed -E "s/^\"$1\":\"//; s/\"\$//; s/\\\\\\\\/\\\\/g"; }

# 1. Worktree
out=$(herdr worktree create --cwd "$root_win" --branch "ticket/$nr" --base "orchestrator/batch" --label "ticket-$nr" --no-focus 2>&1) \
  || die "worktree create failed: $out"
ws=$(field workspace_id "$out"); pane=$(field pane_id "$out"); wt=$(field checkout_path "$out")
[ -n "$ws" ] && [ -n "$pane" ] || die "no workspace/pane id in: $out"

# Gitignored runtime files the build may need.
if [ -n "$wt" ]; then
  command -v cygpath >/dev/null && wt_unix=$(cygpath -u "$wt") || wt_unix=$wt
  for f in "$root"/.env*; do [ -f "$f" ] && cp "$f" "$wt_unix/"; done
fi

# 2. Agent. `agent start` blocks until the agent is ready, and the agent name is not
# resolvable before that, so a folder-trust prompt is answered by pane ID while start runs.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
herdr agent start "$agent" --kind "$kind" --pane "$pane" --timeout 45000 -- "$@" >"$tmp" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
  screen=$(herdr pane read "$pane" --source visible --lines 30 2>&1)
  printf '%s' "$screen" | grep -qiE 'trust this folder|trust the files|do you trust' || continue
  # Default option may be "No, exit": move to the "Yes" line before confirming.
  if printf '%s' "$screen" | grep -qE '❯ *([0-9]\. *)?Yes'; then
    herdr pane send-keys "$pane" enter >/dev/null 2>&1
  else
    herdr pane send-keys "$pane" down >/dev/null 2>&1
  fi
done
wait "$pid"; rc=$?; out=$(cat "$tmp")
if [ $rc -ne 0 ]; then
  screen=$(herdr pane read "$pane" --source visible --lines 30 2>&1)
  die "agent start failed (ws=$ws pane=$pane): $out
screen:
$screen"
fi

# 3. Brief
[ -n "$spec" ] && spec="#${spec#\#}" || spec="none"
[ -n "$notes" ] || notes="none"
brief=$(cat "$template")
brief=${brief//\{nr\}/"$nr"}
brief=${brief//\{spec\}/"$spec"}
brief=${brief//\{notes\}/"$notes"}
out=$(herdr agent prompt "$agent" "$brief" 2>&1) || die "prompt failed (ws=$ws pane=$pane): $out"

echo "ws=$ws pane=$pane agent=$agent path=$wt"
echo "watcher: herdr agent wait \"$agent\" --until working --timeout 15000 >/dev/null 2>&1; s=\$(herdr agent wait \"$agent\" 2>&1); printf '%s\n' \"\$s\" | grep -oE '\"agent_status\":\"[^\"]*\"' | tail -n1"
