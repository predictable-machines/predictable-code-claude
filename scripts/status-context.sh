#!/usr/bin/env sh
# shellcheck shell=sh
#
# Read-only context injector (SessionStart, UserPromptSubmit, PreCompact). Never
# runs `sync` — it only reads the last persisted verdict and surfaces it as
# additionalContext so the agent always knows whether the project is in sync.
# Reading JSON off disk is not a command, so this is portable and cheap.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-status.$$")
cat >"$stdin_json"
event="$(pc_read_event "$stdin_json")"
[ "$event" = "-" ] && event="UserPromptSubmit"
src="$(jq -r '.source // ""' "$stdin_json" 2>/dev/null || echo "")"
rm -f "$stdin_json" 2>/dev/null || true

# A brand-new session resets the per-session "issues found vs fixed" tally so
# the metric reflects THIS session's work. Resume/compact continue it, so only
# the `startup` source clears it.
if [ "$event" = "SessionStart" ] && [ "$src" = "startup" ]; then
  pc_reset_session_history
  rm -f "$(pc_last_verdict_file)" 2>/dev/null || true
fi

verdict_file="$(pc_last_verdict_file)"
verdict="$(pc_verdict_name "$verdict_file")"
pc_log "$event" status-context "$verdict"

# Prefer the session progress summary (issues found vs fixed); fall back to the
# bare verdict / "no sync yet" line before any sync has run this session.
summary="$(pc_session_summary)"
if [ -n "$summary" ]; then
  pc_emit_context "$event" "$summary"
elif ! pc_is_configured; then
  pc_emit_context "$event" "Predictable Code isn't set up here yet — it configures automatically on the first check (run the /predictable-code:sync skill, or it starts on its own), then verifies the code against its spec."
elif [ "$verdict" = "-" ]; then
  pc_emit_context "$event" "Predictable Code: $(pc_verdict_summary "$verdict") to check this project against its spec."
else
  pc_emit_context "$event" "Predictable Code — current verdict: $(pc_verdict_summary "$verdict"). Findings: verification/.analysis-results.json. Re-run predictable sync after edits."
fi
exit 0
