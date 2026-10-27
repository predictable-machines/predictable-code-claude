#!/usr/bin/env sh
# shellcheck shell=sh
#
# Read-only context injector (SessionStart, UserPromptSubmit, PreCompact). Never
# runs `sync` — it only reads the last persisted verdict and surfaces it as
# additionalContext so the agent always knows whether the project is in sync.
# Reading JSON off disk is not a command, so this is portable and cheap. When the
# last sync did NOT run, that is said instead of a verdict it would make look current.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-status.$$")
cat >"$stdin_json"
# The session is what "told the user once" is counted in (pc_sync_failure_untold).
pc_export_session "$stdin_json"
event="$(pc_read_event "$stdin_json")"
[ "$event" = "-" ] && event="UserPromptSubmit"
src="$(jq -r '.source // ""' "$stdin_json" 2>/dev/null || echo "")"
rm -f "$stdin_json" 2>/dev/null || true

# A brand-new session resets the per-session "issues found vs fixed" tally so
# the metric reflects THIS session's work. Resume/compact continue it, so only
# the `startup` source clears it.
#
# The announced-run marker starts at the CURRENT persisted runId so a verdict
# left over from a previous session is never announced as "finished" — only
# syncs that complete DURING this session get the one-shot closing line below.
announced_marker="$(pc_data_dir)/announced-sync-run"
runtime_result="$(pc_state_dir)/.last-sync-response.json"
if [ "$event" = "SessionStart" ] && [ "$src" = "startup" ]; then
  pc_reset_session_history
  rm -f "$(pc_last_verdict_file)" 2>/dev/null || true
  mkdir -p "$(pc_data_dir)" 2>/dev/null || true
  if pc_have_jq && [ -f "$runtime_result" ]; then
    jq -r '.runId // "-"' "$runtime_result" 2>/dev/null >"$announced_marker" || true
  else
    printf '%s\n' '-' >"$announced_marker" 2>/dev/null || true
  fi
fi

verdict_file="$(pc_last_verdict_file)"
verdict="$(pc_verdict_name "$verdict_file")"
pc_log "$event" status-context "$verdict"

# Prefer the session progress summary (issues found vs fixed); fall back to the
# bare verdict / "no sync yet" line before any sync has run this session.
summary="$(pc_session_summary)"
if [ -n "$summary" ]; then
  body="$summary"
elif ! pc_is_configured; then
  body="Predictable Code isn't set up here yet — it configures automatically on the first check (run the /predictable-code:sync skill, or it starts on its own), then verifies the code against its spec."
elif [ "$verdict" = "-" ]; then
  body="Predictable Code: $(pc_verdict_summary "$verdict") to check this project against its spec."
else
  findings="$(pc_state_dir)/specs/.data/findings.json"
  body="Predictable Code — current verdict: $(pc_verdict_summary "$verdict"). Findings: ${findings#"$(pc_project_dir)"/}. Re-run predictable sync after edits."
fi

# Live-check beacon: the product's project sync lock (`.sync.lock` in the state directory)
# names the pid of the sync running RIGHT NOW — the only signal that exists the
# moment a background check starts (the verdict file lands only at the end). The
# injected line tells the agent to ATTACH a background `sync --json` shell to it:
# the lock makes that attach (one pipeline, shared result), the background shell
# is user-visible, and its completion notification is what lets the agent REACT
# when the detached hook sync finishes — a hook cannot wake the agent, but the
# agent's own background task can. A dead pid means a stale lock the product
# clears itself, so only a live one is surfaced.
lock_file="$(pc_sync_lock_file)"
sync_live=0
if [ -f "$lock_file" ] && pc_have_jq; then
  lock_pid="$(pc_lock_pid "$lock_file")"
  case "$lock_pid" in
    ''|*[!0-9]*) lock_pid=0 ;;
  esac
  if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
    sync_live=1
    body="A Predictable Code spec check is running right now (pid $lock_pid). Unless you already have one running this session, start \`predictable sync --json\` NOW as a BACKGROUND shell task (never block your turn on it): the project sync lock makes it attach to the running check and finish together with it, its shell is visible to the user, and its completion notification is your cue to briefly tell the user the verdict (verified/violated counts and findings). Keep working on the user's request meanwhile.

$body"
  fi
fi

# One-shot closing line, the counterpart of session-sync's "syncing in the
# background" toast: when a sync COMPLETED since the last announcement (fresh
# runId in the runtime's persisted response, and no LIVE lock), surface a single
# user-visible systemMessage with the verdict alongside the context injection —
# a hook cannot speak at the moment the detached sync ends, so the next prompt
# is the earliest deterministic in-UI slot.
announce=""
if pc_have_jq && [ -f "$runtime_result" ] && [ "$sync_live" -eq 0 ]; then
  current_run="$(jq -r '.runId // "-"' "$runtime_result" 2>/dev/null || printf '%s' '-')"
  last_announced="$(cat "$announced_marker" 2>/dev/null || printf '')"
  if [ "$current_run" != "-" ] && [ "$current_run" != "$last_announced" ]; then
    run_verdict="$(jq -r '.response | keys[0] // "-"' "$runtime_result" 2>/dev/null || printf '%s' '-')"
    announce="Predictable Code: sync finished — $(pc_verdict_summary "$run_verdict")."
    mkdir -p "$(pc_data_dir)" 2>/dev/null || true
    printf '%s\n' "$current_run" >"$announced_marker" 2>/dev/null || true
  fi
fi

# A sync that did not run (refused, or failed) comes first, for as long as it stands —
# the agent is told on every turn, like the verdict it would otherwise read as current,
# and the user once per session. A sync live right now has got past the point where
# the CLI refuses a checkout, so the standing failure is likely resolved and is not
# repeated over the beacon; the sync's own outcome replaces or clears it.
notice=""
if [ "$sync_live" -eq 0 ]; then
  failure="$(pc_sync_failure_standing)"
  if [ -n "$failure" ]; then
    body="$(pc_sync_failure_context "$failure")

$body"
    untold="$(pc_sync_failure_untold)"
    [ -n "$untold" ] && notice="$(pc_sync_failure_notice "$untold")"
  fi
fi
message="$notice"
if [ -n "$announce" ]; then
  if pc_verdict_alarms "$run_verdict"; then
    message="${message:+$message
}$announce"
  else
    # Routine: the status line shows it to the user; the agent reads it here.
    body="$announce${body:+

$body}"
  fi
fi

# The brand + AskUserQuestion rules ride on every turn's context so they apply
# session-wide, not only inside the sync skill.
context_text="$(pc_brand_style_rule)
$(pc_askquestion_rule)
$body"
if [ -n "$message" ] && pc_have_jq; then
  jq -n --arg e "$event" --arg c "$context_text" --arg m "$message" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
else
  pc_emit_context "$event" "$context_text"
fi
exit 0
