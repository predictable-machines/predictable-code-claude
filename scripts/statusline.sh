#!/usr/bin/env sh
# shellcheck shell=sh
#
# Claude Code statusline: the deterministic "you can SEE the background sync"
# surface. statusLine is settings-only (plugins cannot ship one), so
# session-sync wires this script into the project's .claude/settings.local.json
# when the user has no statusline of their own; with refreshInterval it keeps
# re-running while the session idles, so it needs NO model cooperation to show
# a hook-detached sync — the thing no shell panel can ever display.
#
# One line: model · project dir · Predictable state, read from the runtime's
# two files: `.predictable-code/.sync.lock` (a LIVE pid = a sync is running
# right now) and `.predictable-code/.last-sync-response.json` (last verdict).

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude'
  exit 0
fi

project=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .cwd // ""' 2>/dev/null || printf '')
model=$(printf '%s' "$input" | jq -r '.model.display_name // ""' 2>/dev/null || printf '')

segment=""
lock="$project/.predictable-code/.sync.lock"
result="$project/.predictable-code/.last-sync-response.json"

if [ -n "$project" ] && [ -f "$lock" ]; then
  lock_pid=$(jq -r '.pid // 0' "$lock" 2>/dev/null || printf '0')
  case "$lock_pid" in
    '' | *[!0-9]*) lock_pid=0 ;;
  esac
  if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
    segment="Predictable ⏳ syncing…"
  fi
fi

if [ -z "$segment" ] && [ -n "$project" ] && [ -f "$result" ]; then
  verdict=$(jq -r '.response | keys[0] // ""' "$result" 2>/dev/null || printf '')
  case "$verdict" in
    mechanical)
      segment=$(jq -r '.response.mechanical | "Predictable ✓ \(.requirementsVerified) verified · \(.requirementsViolated) violated · \(.findingsTotal) findings"' \
        "$result" 2>/dev/null || printf '')
      ;;
    inSync) segment="Predictable ✓ in sync" ;;
    degraded) segment="Predictable △ partial translation" ;;
    specViolation) segment="Predictable ✗ spec violation" ;;
    verificationError) segment="Predictable ✗ verification error" ;;
    *) segment="" ;;
  esac
fi

line="$model"
if [ -n "$project" ]; then
  line="$line · $(basename "$project")"
fi
if [ -n "$segment" ]; then
  line="$line · $segment"
fi
printf '%s' "$line"
exit 0
