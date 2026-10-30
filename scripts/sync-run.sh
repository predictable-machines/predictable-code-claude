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
pc_export_session "$stdin_json"
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

verdict_file="$(pc_last_verdict_file)"

run_sync() { # event
  # `sync --json --claude` prints the SyncResponse to stdout (and auto-initializes
  # the project with Claude defaults if it isn't set up — product-side, so this hook
  # never checks config). Persist it atomically so a partial write never corrupts the
  # verdict a later hook reads, then record the outcome in the session history that
  # feeds the "issues found vs fixed" metric. A run that did not happen leaves the
  # verdict alone and never traps the turn, but it is RECORDED with the reason its
  # stderr gave: this sync is usually detached, so the hooks after it are the ones
  # that can say it (the next Stop to the user, the next prompt to the agent).
  tmp="$verdict_file.tmp.$$"
  err="$(pc_stderr_file)"
  # A task the statusline can estimate (`pc_task_begin`): its time is measured here,
  # where the sync starts and ends, and the next sync's estimate is read from it.
  task="$(pc_task_begin sync sync "sync" "$(pc_self_pid)")"
  pc_run_sync "$tmp" "$err"
  code=$?
  if [ "$code" -eq 0 ]; then pc_task_end "$task" ok; else pc_task_end "$task" failed; fi
  if [ "$code" -eq 0 ]; then
    mv "$tmp" "$verdict_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    pc_record_sync "$1" "$verdict_file"
    pc_clear_sync_failure
  else
    rm -f "$tmp" 2>/dev/null || true
    pc_record_sync_failure "$1" "$code" \
      "$(pc_sync_failure_text "$code" "$(pc_sync_failure_reason "$err")")" no
    pc_log "$1" sync-run "failed-$code"
  fi
  rm -f "$err" 2>/dev/null || true
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

# A sync that did not run, said first. On Stop the advisory is the user's
# (systemMessage), so it is said once per session per distinct failure rather than at
# every turn end; on an event whose advisory is the agent's context it stands every
# time, like the verdict it replaces.
case "$event" in
  Stop | SubagentStop)
    failure="$(pc_sync_failure_untold)"
    [ -n "$failure" ] && failure="$(pc_sync_failure_notice "$failure")"
    ;;
  *)
    failure="$(pc_sync_failure_standing)"
    [ -n "$failure" ] && failure="$(pc_sync_failure_context "$failure")"
    ;;
esac

# Surface the session progress — how many issues Predictable found and how many
# Claude has fixed — as context (advisory; never blocks the turn). On Stop this
# reads as the closing "proven in sync" summary once the code lands in sync.
summary="$(pc_session_summary)"
# On Stop the summary is the USER's (systemMessage), said only when the verdict asks
# them to act; a routine one is on the status line already (`pc_verdict_alarms`).
case "$event" in
  Stop | SubagentStop) pc_verdict_alarms "$(pc_verdict_name "$verdict_file")" || summary="" ;;
esac
advisory="$failure"
if [ -n "$summary" ]; then
  advisory="${advisory:+$advisory
}$summary"
fi
if [ -n "$advisory" ]; then
  emit_advisory "$advisory"
fi

rm -f "$stdin_json" 2>/dev/null || true
exit 0
