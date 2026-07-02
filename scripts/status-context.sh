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
rm -f "$stdin_json" 2>/dev/null || true

verdict_file="$(pc_last_verdict_file)"
verdict="$(pc_verdict_name "$verdict_file")"
pc_log "$event" status-context "$verdict"

summary="$(pc_verdict_summary "$verdict")"
if [ "$verdict" = "-" ]; then
  pc_emit_context "$event" "Predictable Code: $summary to check this project against its spec."
else
  pc_emit_context "$event" "Predictable Code — current verdict: $summary. Findings: verification/.analysis-results.json. Re-run \`predictable sync\` after edits."
fi
exit 0
