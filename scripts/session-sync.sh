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
# Make the invisible visible. The detached sync above can NEVER appear in the
# user's shell panel — that panel only shows tasks the agent itself launches —
# so one combined JSON carries both audiences: a one-line `systemMessage` for
# the user, and `additionalContext` instructing the agent to start an ATTACH
# task on its first turn (the product's sync lock joins it to the running
# check: one pipeline, shared result). The attach task is what gives the user
# a visible shell AND gives the agent a completion notification to react to.
# Instructed HERE, not via the lock beacon, because the beacon races the
# check's duration (a fast check can finish before the first prompt).
sync_cmd="$bin"
[ -x "$bin" ] || sync_cmd="predictable"
if pc_have_jq; then
  jq -n \
    --arg message "Predictable Code is syncing the project in the background." \
    --arg context "A Predictable Code spec check was just started in the background (detached from a hook, so it has no visible shell). On your FIRST turn this session, before other tool calls, start \`$sync_cmd sync --json\` as a BACKGROUND shell task and keep working — never block a turn on it. The project sync lock makes it attach to the running check (one pipeline, shared result; if the check already finished it re-checks incrementally and fast). Its shell is the user's window into the sync, and its completion notification is your cue to briefly report the verdict (verified/violated counts and findings)." \
    '{systemMessage: $message, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}'
else
  pc_emit_system_message "Predictable Code is syncing the project in the background."
fi
exit 0
