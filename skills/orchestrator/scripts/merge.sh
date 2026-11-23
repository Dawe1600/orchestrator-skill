#!/usr/bin/env bash
# Merge ticket/<nr> into orchestrator/batch inside the merge worktree, then run the gate.
# Usage: merge.sh <nr> <merge-worktree>   (run from the repo; creates the merge worktree if missing)
# Overrides: INSTALL_CMD, BUILD_CMD, TEST_CMD (empty string "" skips that step).
# Exit: 0 merged + green, 1 error, 2 conflict (merge left in progress), 3 install/build/test red.
set -u
die() { echo "merge: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: merge.sh <nr> <merge-worktree>"
nr=$1 mw=$2 br="ticket/$nr"

git rev-parse --verify -q "refs/heads/$br" >/dev/null || die "no branch $br"
if [ ! -d "$mw" ]; then
  git worktree add "$mw" orchestrator/batch >/dev/null 2>&1 || die "cannot create merge worktree $mw"
  first=1
fi
cd "$mw" || die "no merge worktree $mw"
[ "$(git branch --show-current)" = orchestrator/batch ] || die "$mw is not on orchestrator/batch"
[ -z "$(git status --porcelain -uno)" ] || die "$mw has uncommitted changes"

before=$(git rev-parse HEAD)
# The merge worktree has orchestrator/batch checked out, so `git fetch . br:orchestrator/batch`
# is refused here; `merge --ff-only` is the same fast-forward and also updates the files.
if git merge --ff-only -q "$br" >/dev/null 2>&1; then how=ff
elif git merge --no-edit -q "$br" >/dev/null 2>&1; then how=merge
else
  files=$(git diff --name-only --diff-filter=U)
  [ -n "$files" ] || die "merge failed without conflicts: $(git merge --no-edit "$br" 2>&1 | tail -n3)"
  echo "CONFLICT merging $br into orchestrator/batch in $mw:"
  printf '%s\n' "$files" | sed 's/^/  /'
  exit 2
fi
sha=$(git rev-parse --short HEAD)
[ "$(git rev-parse HEAD)" = "$before" ] && how=already-merged

# Gate commands: overrides, else npm scripts that exist.
has_script() { [ -f package.json ] && node -e "process.exit(require('./package.json').scripts?.['$1']?0:1)" 2>/dev/null; }
pkg_changed=$(git diff --name-only "$before" HEAD -- package.json)
if [ -n "${INSTALL_CMD+x}" ]; then install=$INSTALL_CMD
elif [ -f package.json ] && { [ -n "${first:-}" ] || [ ! -d node_modules ] || [ -n "$pkg_changed" ]; }; then install="npm install"
else install=""; fi
if [ -n "${BUILD_CMD+x}" ]; then build=$BUILD_CMD; elif has_script build; then build="npm run build"; else build=""; fi
if [ -n "${TEST_CMD+x}" ]; then test=$TEST_CMD; elif has_script test; then test="npm test"; else test=""; fi

result="merged $br -> orchestrator/batch $sha ($how)"
for step in install build test; do
  cmd=${!step}
  [ -n "$cmd" ] || { result="$result $step=skip"; continue; }
  log=$(bash -c "$cmd" 2>&1)
  if [ $? -ne 0 ]; then
    echo "$result $step=FAIL ($cmd)"; printf '%s\n' "$log" | tail -n 30; exit 3
  fi
  result="$result $step=pass"
  [ "$step" = test ] && summary=$(printf '%s\n' "$log" | grep -E '^(#|ℹ) (tests|pass|fail) ' | tr '\n' ' ')
done
echo "$result${summary:+ | $summary}"
