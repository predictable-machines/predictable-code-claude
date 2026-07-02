#!/usr/bin/env sh
# shellcheck shell=sh
#
# Advisory sync hook (PostToolUse on source edits, Stop, SubagentStop).
#
# `predictable sync` is heavy, so on these hot-path events we DON'T block on it:
# we kick it off in the background (writing its verdict to the shared
# last-verdict file) and immediately surface the *previous* verdict as
# additionalContext. The next turn's status-context picks up the fresh verdict.
# Set PREDICTABLE_SYNC_FOREGROUND=1 to run synchronously (used by the L1 tests
# and available for debugging).

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-sync-run.$$")
cat >"$stdin_json"
event="$(pc_read_event "$stdin_json")"
[ "$event" = "-" ] && event="PostToolUse"

# Matcher label for the audit log: the tool name when present, else the event.
matcher="$(jq -r '.tool_name // .toolName // "-"' "$stdin_json" 2>/dev/null || echo "-")"
[ "$matcher" = "-" ] && matcher="$event"

project="$(pc_project_dir)"
bin="$(pc_predictable_bin)"
verdict_file="$(pc_last_verdict_file)"

run_sync() {
  # `sync --json` prints the SyncResponse to stdout; persist it atomically so a
  # partial write never corrupts the verdict a later hook reads.
  tmp="$verdict_file.tmp.$$"
  if ( cd "$project" 2>/dev/null && "$bin" sync --json ) >"$tmp" 2>/dev/null; then
    mv "$tmp" "$verdict_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

if [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ]; then
  run_sync
else
  # Detach so the hook returns immediately; the fresh verdict lands for the next
  # turn. nohup + `&` keeps it alive past hook teardown.
  ( run_sync ) >/dev/null 2>&1 &
fi

verdict="$(pc_verdict_name "$verdict_file")"
pc_log "$event" "$matcher" "$verdict"

if [ "$verdict" != "-" ] && [ "$verdict" != "inSync" ]; then
  pc_emit_context "$event" "Predictable Code — last verdict: $(pc_verdict_summary "$verdict"). See verification/.analysis-results.json. A fresh \`predictable sync\` is running."
fi

rm -f "$stdin_json" 2>/dev/null || true
exit 0
