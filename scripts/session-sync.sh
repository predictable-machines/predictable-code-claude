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

# Don't pile onto an in-flight sync (see pc_sync_running — two syncs on one project
# race the engine into a runaway).
if pc_sync_running; then
  pc_log SessionStart session-sync skipped-running
  exit 0
fi

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
# Build (once, cached) a tiny AppleScript applet whose bundle carries the brand
# Λ as its app icon. macOS notifications always show the POSTING app's icon and
# name — `display notification` has no icon parameter — so the only
# zero-install way to brand them is to BE the app: osacompile + sips + iconutil
# all ship with macOS. Rebuilt when the logo changes (mtime stamp); any build
# failure just means the caller falls back to plain osascript. First
# notification from the applet triggers the standard one-time permission
# prompt for "Predictable Code".
ensure_notifier_app() { # logo-png -> prints applet executable path on success
  notifier_dir="$(pc_data_dir)/notifier"
  applet_bin="$notifier_dir/Predictable Code.app/Contents/MacOS/applet"
  logo_png="$1"
  [ -f "$logo_png" ] || return 1
  command -v osacompile >/dev/null 2>&1 || return 1
  command -v sips >/dev/null 2>&1 || return 1
  command -v iconutil >/dev/null 2>&1 || return 1
  logo_stamp="$(stat -f %m "$logo_png" 2>/dev/null || stat -c %Y "$logo_png" 2>/dev/null || printf '0')"
  built_stamp="$(cat "$notifier_dir/.logo-stamp" 2>/dev/null || printf '')"
  if [ -x "$applet_bin" ] && [ "$logo_stamp" = "$built_stamp" ]; then
    printf '%s' "$applet_bin"
    return 0
  fi
  build_dir="$(mktemp -d 2>/dev/null)" || return 1
  # The applet reads its message from `message.txt` NEXT TO its own bundle, not
  # from the environment: it is launched via `open` (LaunchServices), which is
  # what registers the app and triggers the notification-permission prompt —
  # a directly-exec'd applet can stay unregistered and macOS then drops its
  # notifications silently, without ever prompting. `open` does not forward
  # the caller's environment, hence the sibling file.
  cat >"$build_dir/notify.applescript" <<'APPLESCRIPT'
try
  set msgFile to (POSIX path of (path to me)) & "/../message.txt"
  set msg to read (POSIX file msgFile) as «class utf8»
on error
  set msg to "Sync finished."
end try
display notification msg with title "Predictable Code"
APPLESCRIPT
  if ! osacompile -o "$build_dir/Predictable Code.app" "$build_dir/notify.applescript" >/dev/null 2>&1; then
    rm -rf "$build_dir" 2>/dev/null || true
    return 1
  fi
  mkdir -p "$build_dir/icon.iconset" 2>/dev/null || true
  for icon_size in 16 32 128 256; do
    sips -z "$icon_size" "$icon_size" "$logo_png" \
      --out "$build_dir/icon.iconset/icon_${icon_size}x${icon_size}.png" >/dev/null 2>&1 || true
  done
  # A failed icns build keeps the stock applet icon — still branded by NAME.
  if iconutil -c icns -o "$build_dir/applet.icns" "$build_dir/icon.iconset" >/dev/null 2>&1; then
    cp "$build_dir/applet.icns" "$build_dir/Predictable Code.app/Contents/Resources/applet.icns" 2>/dev/null || true
  fi
  rm -rf "$notifier_dir" 2>/dev/null || true
  mkdir -p "$notifier_dir" 2>/dev/null || true
  if mv "$build_dir/Predictable Code.app" "$notifier_dir/" 2>/dev/null; then
    printf '%s' "$logo_stamp" >"$notifier_dir/.logo-stamp" 2>/dev/null || true
    rm -rf "$build_dir" 2>/dev/null || true
    [ -x "$applet_bin" ] && printf '%s' "$applet_bin" && return 0
  fi
  rm -rf "$build_dir" 2>/dev/null || true
  return 1
}

# Post one branded notification through the applet: write the sibling message
# file, launch the BUNDLE via `open` (-g: no focus steal, -j: hidden). Returns
# non-zero when the applet is unavailable so the caller can fall back.
post_branded_notification() { # logo-png message
  applet_exec="$(ensure_notifier_app "$1" || printf '')"
  [ -n "$applet_exec" ] || return 1
  applet_bundle="${applet_exec%/Contents/MacOS/applet}"
  printf '%s' "$2" >"$(dirname "$applet_bundle")/message.txt" 2>/dev/null || return 1
  open -gj "$applet_bundle" >/dev/null 2>&1 || return 1
  return 0
}

notify_sync_done() { # verdict-file
  [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ] && return 0
  finished_verdict="$(pc_verdict_name "$1")"
  message="Sync finished — $(pc_verdict_summary "$finished_verdict")"
  logo="${CLAUDE_PLUGIN_ROOT:-$self_dir/..}/assets/logo.png"
  case "$(uname -s)" in
    Darwin)
      # Zero-install branded notification via the self-built applet (own icon +
      # own name); plain osascript — Script Editor identity, no logo — only when
      # the applet cannot be built or launched.
      if post_branded_notification "$logo" "$message"; then
        :
      else
        osascript -e "display notification \"$message\" with title \"Predictable Code\"" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      if command -v notify-send >/dev/null 2>&1; then
        if [ -f "$logo" ]; then
          notify-send -i "$logo" "Predictable Code" "$message" >/dev/null 2>&1 || true
        else
          notify-send "Predictable Code" "$message" >/dev/null 2>&1 || true
        fi
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

if [ "${PREDICTABLE_SYNC_FOREGROUND:-}" = "1" ]; then
  run_first_sync
else
  ( run_first_sync ) >/dev/null 2>&1 &
fi

pc_log SessionStart session-sync started
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
