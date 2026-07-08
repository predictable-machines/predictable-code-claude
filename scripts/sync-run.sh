#!/usr/bin/env sh
# shellcheck shell=sh
#
# Advisory sync hook (Stop, SubagentStop — turn-end verification).
#
# `predictable sync` is heavy, so we DON'T block on it: we kick it off in the
# background (writing its verdict to the shared last-verdict file) and immediately
# surface the current session summary as an advisory (systemMessage on Stop/
# SubagentStop — see emit_advisory). The next turn's status-context picks up the
# fresh verdict.
#
# We NEVER launch a sync while another is already running (pc_sync_running). Edits
# are NOT a trigger: the skill runs its OWN foreground `predictable sync --json`
# after editing (the Fix-issue / New-feature flows), so an edit-triggered hook sync
# would collide with it — two syncs on one project race the engine's setup-progress
# watcher into a runaway (multi-GB stdout / pegged CPU). This hook only fills the
# gap at turn end when nothing else synced.
#
# Set PREDICTABLE_SYNC_FOREGROUND=1 to run synchronously (used by the L1 tests).

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-sync-run.$$")
cat >"$stdin_json"
event="$(pc_read_event "$stdin_json")"
[ "$event" = "-" ] && event="Stop"

# Route an advisory to the right output shape for this event. Stop/SubagentStop
# (this hook's wired events) accept only top-level fields, so their advisory (the
# closing "proven in sync" summary) goes through `systemMessage`; additionalContext
# would fail schema validation there. The other branch is a fallback for any event
# that does accept additionalContext.
emit_advisory() { # message
  case "$event" in
    Stop | SubagentStop) pc_emit_system_message "$1" ;;
    *) pc_emit_context "$event" "$1" ;;
  esac
}

# Matcher label for the audit log: the tool name when present, else the event.
matcher="$(jq -r '.tool_name // .toolName // "-"' "$stdin_json" 2>/dev/null || echo "-")"
[ "$matcher" = "-" ] && matcher="$event"

project="$(pc_project_dir)"
bin="$(pc_predictable_bin)"
verdict_file="$(pc_last_verdict_file)"

# Guarantee the project is initialized before syncing (shared invariant — sync
# needs it in every case, incl. fresh worktrees). Only when init can't run (no
# runtime) do we advise and step aside — never trap the turn.
if ! pc_ensure_init; then
  pc_log "$event" "$matcher" not-configured
  emit_advisory "Predictable Code couldn't initialize this project (runtime unavailable) — run the /predictable-code:sync skill to set it up."
  rm -f "$stdin_json" 2>/dev/null || true
  exit 0
fi

run_sync() { # event
  # `sync --json` prints the SyncResponse to stdout; persist it atomically so a
  # partial write never corrupts the verdict a later hook reads, then record the
  # outcome in the session history that feeds the "issues found vs fixed" metric.
  tmp="$verdict_file.tmp.$$"
  if ( cd "$project" 2>/dev/null && "$bin" sync --json ) >"$tmp" 2>/dev/null; then
    mv "$tmp" "$verdict_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    pc_record_sync "$1" "$verdict_file"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

launch_sync() {
  if [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ]; then
    run_sync "$event"
  else
    # Detach so the hook returns immediately; the fresh verdict lands for the next
    # turn. `&` keeps it alive past hook teardown.
    ( run_sync "$event" ) >/dev/null 2>&1 &
  fi
}

# Never run two syncs at once on the same project (pc_sync_running). The skill
# drives its own foreground `predictable sync --json`; when one is in flight this
# hook skips and only reports — two concurrent syncs race the engine into a runaway.
if pc_sync_running; then
  pc_log "$event" "$matcher" skipped-running
else
  launch_sync
  pc_log "$event" "$matcher" "$(pc_verdict_name "$verdict_file")"
fi

# Surface the session progress — how many issues Predictable found and how many
# Claude has fixed — as context (advisory; never blocks the turn). On Stop this
# reads as the closing "proven in sync" summary once the code lands in sync.
summary="$(pc_session_summary)"
if [ -n "$summary" ]; then
  emit_advisory "$summary"
fi

rm -f "$stdin_json" 2>/dev/null || true
exit 0
