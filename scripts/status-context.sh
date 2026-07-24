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
  body="$summary"
elif ! pc_is_configured; then
  body="Predictable Code isn't set up here yet — it configures automatically on the first check (run the /predictable-code:sync skill, or it starts on its own), then verifies the code against its spec."
elif [ "$verdict" = "-" ]; then
  body="Predictable Code: $(pc_verdict_summary "$verdict") to check this project against its spec."
else
  body="Predictable Code — current verdict: $(pc_verdict_summary "$verdict"). Findings: verification/.analysis-results.json. Re-run predictable sync after edits."
fi

# Live-check beacon: the product's project sync lock (`.predictable-code/.sync.lock`)
# names the pid of the sync running RIGHT NOW — the only signal that exists the
# moment a background check starts (the verdict file lands only at the end). The
# injected line tells the agent to ATTACH a background `sync --json` shell to it:
# the lock makes that attach (one pipeline, shared result), the background shell
# is user-visible, and its completion notification is what lets the agent REACT
# when the detached hook sync finishes — a hook cannot wake the agent, but the
# agent's own background task can. A dead pid means a stale lock the product
# clears itself, so only a live one is surfaced.
lock_file="$(pc_project_dir)/.predictable-code/.sync.lock"
if [ -f "$lock_file" ] && pc_have_jq; then
  lock_pid="$(jq -r '.pid // 0' "$lock_file" 2>/dev/null || printf '0')"
  case "$lock_pid" in
    ''|*[!0-9]*) lock_pid=0 ;;
  esac
  if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
    body="A Predictable Code spec check is running right now (pid $lock_pid). Unless you already have one running this session, start \`predictable sync --json\` NOW as a BACKGROUND shell task (never block your turn on it): the project sync lock makes it attach to the running check and finish together with it, its shell is visible to the user, and its completion notification is your cue to briefly tell the user the verdict (verified/violated counts and findings). Keep working on the user's request meanwhile.

$body"
  fi
fi

# The brand + AskUserQuestion rules ride on every turn's context so they apply
# session-wide, not only inside the sync skill.
pc_emit_context "$event" "$(pc_brand_style_rule)
$(pc_askquestion_rule)
$body"
exit 0
