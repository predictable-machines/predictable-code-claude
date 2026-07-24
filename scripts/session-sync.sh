#!/usr/bin/env sh
# shellcheck shell=sh
#
# SessionStart(startup): kick off the first `predictable sync --json --claude`
# DETACHED. `--claude` makes the PRODUCT auto-initialize the project (Claude
# defaults + source detection) when it isn't set up yet, so this hook does NOT
# check or init anything — it just runs sync. That is what self-configures a fresh
# session and, crucially, a fresh git WORKTREE (a clean checkout with no
# `.predictable-code/`, which is gitignored so it is NEVER carried over).
#
# Never blocks the session: only runs on `startup`, requires a git repo + a usable
# runtime, and the sync is detached so SessionStart returns immediately. The verdict
# lands for the next turn, where status-context surfaces it.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-session-sync.$$")
cat >"$stdin_json"
src="$(jq -r '.source // ""' "$stdin_json" 2>/dev/null || echo "")"
rm -f "$stdin_json" 2>/dev/null || true

# Only self-configure on a brand-new session; resume/compact already have state.
[ "$src" = "startup" ] || exit 0

project="$(pc_project_dir)"
bin="$(pc_predictable_bin)"

# Never scaffold outside a real project: require a git repo (a worktree IS one)
# and a usable `predictable`. Otherwise no-op silently (bootstrap already advised
# on a missing runtime).
( cd "$project" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) || exit 0
if [ ! -x "$bin" ] && ! command -v predictable >/dev/null 2>&1; then
  exit 0
fi

# Don't pile onto an in-flight sync (see pc_sync_running — two syncs on one project
# race the engine into a runaway).
if pc_sync_running; then
  pc_log SessionStart session-sync skipped-running
  exit 0
fi

# Fire the first sync DETACHED; SessionStart returns now, the verdict lands next
# turn. `--claude` auto-inits the project if needed (product-side). PREDICTABLE_SYNC_
# FOREGROUND=1 runs it synchronously (L1 tests / debugging).
verdict_file="$(pc_last_verdict_file)"
run_first_sync() {
  tmp="$verdict_file.tmp.$$"
  if ( cd "$project" 2>/dev/null && "$bin" sync --json --claude ) >"$tmp" 2>/dev/null; then
    mv "$tmp" "$verdict_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    pc_record_sync SessionStart "$verdict_file"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

if [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ]; then
  run_first_sync
else
  ( run_first_sync ) >/dev/null 2>&1 &
fi

pc_log SessionStart session-sync started
# Make the invisible visible: this is the user's ONLY signal that a background
# check just started (the sync is detached and silent, and the verdict file
# only lands when it finishes). systemMessage is user-facing UI, not model
# context — status-context carries the model-side "a check is running" line.
pc_emit_system_message "Predictable Code is syncing the project in the background."
exit 0
