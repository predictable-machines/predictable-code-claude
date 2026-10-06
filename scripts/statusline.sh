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
# two files in the branch's state directory: `.sync.lock` (a LIVE pid = a sync
# is running right now) and `.last-sync-response.json` (last verdict).

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude'
  exit 0
fi

project=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .cwd // ""' 2>/dev/null || printf '')
model=$(printf '%s' "$input" | jq -r '.model.display_name // ""' 2>/dev/null || printf '')

segment=""
# In a git checkout `.predictable-code/` is the DATABASE (a worktree of
# `predictable-code-database`, its `.git` a file), and the branch's state is its
# entry; the same rule as `pc_state_dir`, which this script cannot source.
state="$project/.predictable-code"
if [ -n "$project" ] && [ -f "$state/.git" ]; then
  branch=$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '.detached')
  state="$state/$branch/.predictable-code"
fi
lock="$state/.sync.lock"
result="$state/.last-sync-response.json"

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
  # Age suffix so a ✓ is unambiguous ("finished, N min ago"), never confusable
  # with a verdict left over from an older run. BSD stat first (macOS), GNU
  # fallback; no age shown when neither works.
  if [ -n "$segment" ]; then
    result_mtime=$(stat -f %m "$result" 2>/dev/null || stat -c %Y "$result" 2>/dev/null || printf '')
    now_epoch=$(date +%s 2>/dev/null || printf '')
    if [ -n "$result_mtime" ] && [ -n "$now_epoch" ]; then
      age=$((now_epoch - result_mtime))
      if [ "$age" -ge 3600 ]; then
        age_label="$((age / 3600))h"
      else
        if [ "$age" -ge 60 ]; then age_label="$((age / 60))m"; else age_label="${age}s"; fi
      fi
      segment="$segment ($age_label ago)"
    fi
  fi
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
