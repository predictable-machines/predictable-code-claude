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
pc_export_session "$stdin_json"
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

# NOTE: an in-flight sync no longer short-circuits this hook. Only the FIRE of
# a new sync is skipped (below) — the statusline wiring and the user-facing
# toast must happen regardless, and skipping them here was exactly how a stuck
# "running" reading silently killed the whole session-start UX. The runtime's
# sync lock makes a second launch harmless anyway (it attaches), so the skip is
# a courtesy, not a safety requirement.

# Deterministic visibility: wire the plugin statusline into the project's
# .claude/settings.local.json when NO statusLine is configured in any settings
# file we can see (user / project / local) — never clobber an existing one.
# statusLine is a settings-only surface (plugins cannot ship it), and
# refreshInterval keeps it re-running while the session idles, so the detached
# sync below stays visible — running and finished — without any model
# cooperation. Hot-reload applies it from the first interaction.
ensure_statusline() {
  pc_have_jq || return 0
  for settings_file in "$HOME/.claude/settings.json" "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
    if [ -f "$settings_file" ] && jq -e '.statusLine' "$settings_file" >/dev/null 2>&1; then
      return 0
    fi
  done
  statusline_script="${CLAUDE_PLUGIN_ROOT:-$self_dir/..}/scripts/statusline.sh"
  [ -x "$statusline_script" ] || return 0
  mkdir -p "$project/.claude" 2>/dev/null || return 0
  local_settings="$project/.claude/settings.local.json"
  existing_settings="{}"
  if [ -f "$local_settings" ]; then
    existing_settings="$(cat "$local_settings" 2>/dev/null || printf '{}')"
  fi
  tmp_settings="$local_settings.tmp.$$"
  if printf '%s' "$existing_settings" | jq --arg cmd "$statusline_script" \
    '. + {statusLine: {type: "command", command: $cmd, refreshInterval: 2, padding: 0}}' \
    >"$tmp_settings" 2>/dev/null; then
    mv "$tmp_settings" "$local_settings" 2>/dev/null || rm -f "$tmp_settings" 2>/dev/null || true
    pc_log SessionStart session-sync statusline-wired
  else
    rm -f "$tmp_settings" 2>/dev/null || true
  fi
}
ensure_statusline

# Native OS notification when the detached sync finishes — the completion-side
# counterpart of the statusline (Claude cannot be woken by a hook process, but
# the OS can tell the user directly). Best-effort and silent on failure;
# skipped in FOREGROUND mode so L1 test runs never pop notifications.
notify_sync_done() { # verdict-file
  [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ] && return 0
  finished_verdict="$(pc_verdict_name "$1")"
  message="Sync finished — $(pc_verdict_summary "$finished_verdict")"
  case "$(uname -s)" in
    Darwin)
      osascript -e "display notification \"$message\" with title \"Predictable Code\"" >/dev/null 2>&1 || true
      ;;
    *)
      if command -v notify-send >/dev/null 2>&1; then
        notify-send "Predictable Code" "$message" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# Fire the first sync DETACHED; SessionStart returns now, the verdict lands next
# turn. `--claude` auto-inits the project if needed (product-side). PREDICTABLE_SYNC_
# FOREGROUND=1 runs it synchronously (L1 tests / debugging).
verdict_file="$(pc_last_verdict_file)"
run_first_sync() {
  tmp="$verdict_file.tmp.$$"
  if ( cd "$project" 2>/dev/null && "$bin" sync --json --claude ) >"$tmp" 2>/dev/null; then
    mv "$tmp" "$verdict_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    pc_record_sync SessionStart "$verdict_file"
    notify_sync_done "$verdict_file"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

if pc_sync_running; then
  pc_log SessionStart session-sync skipped-running
else
  if [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ]; then
    run_first_sync
  else
    ( run_first_sync ) >/dev/null 2>&1 &
  fi
  pc_log SessionStart session-sync started
fi
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
