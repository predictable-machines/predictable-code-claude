# shellcheck shell=sh
# Shared helpers for the Predictable Code hook scripts.
#
# POSIX sh, meant to be *sourced* (not executed). Every hook script sources this
# so the runtime-dir / project-dir / logging / verdict-reading logic lives in one
# place. Deliberately dependency-light: only `jq` is assumed, and its absence is
# tolerated (hooks must never hard-fail a host session — see the plan's
# "exit-code discipline" risk note).

# Persistent data dir: runtime bundle, event log, last verdict. Host-provided
# when available (`CLAUDE_PLUGIN_DATA` / Codex `PLUGIN_DATA`), else a stable
# per-user default so the standalone/dev path still works.
pc_data_dir() {
  printf '%s' "${CLAUDE_PLUGIN_DATA:-${PLUGIN_DATA:-$HOME/.predictable-code-runtime}}"
}

# The project the host session is operating on — where `predictable sync` runs
# and reads/writes `.predictable-code/` and `verification/`.
pc_project_dir() {
  printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}"
}

# The `predictable` entry point. Tests override via `PREDICTABLE_BIN` (a stub
# that prints a canned SyncResponse) so the hook contract is exercisable with no
# runtime bundle and no LLM. Otherwise the vendored wrapper, which resolves the
# downloaded runtime (or a dev `predictable` on PATH).
pc_predictable_bin() {
  if [ -n "${PREDICTABLE_BIN:-}" ]; then
    printf '%s' "$PREDICTABLE_BIN"
    return 0
  fi
  printf '%s' "${CLAUDE_PLUGIN_ROOT:-.}/bin/predictable"
}

pc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

pc_have_jq() { command -v jq >/dev/null 2>&1; }

# Append one audit line: `<iso8601> <event> <matcher> <verdict>`. This is the
# observable side effect the L5 integration tests assert on ("hooks fired"), so
# it is best-effort but always attempted, even when jq is missing.
pc_log() { # event matcher verdict
  _pc_data="$(pc_data_dir)"
  mkdir -p "$_pc_data" 2>/dev/null || true
  printf '%s %s %s %s\n' "$(pc_now)" "${1:-?}" "${2:--}" "${3:--}" \
    >>"$_pc_data/hook-events.log" 2>/dev/null || true
}

# Where sync-run persists the last SyncResponse so status-context (and the next
# turn's UserPromptSubmit/SessionStart) can surface it without re-running sync.
pc_last_verdict_file() { printf '%s/last-verdict.json' "$(pc_data_dir)"; }

# SyncResponse is `{constructorName: {…}}`; the constructor name IS the verdict.
# Returns one of inSync|specViolation|verificationError, or '-' when
# absent/unreadable.
pc_verdict_name() { # file
  if [ ! -f "$1" ] || ! pc_have_jq; then
    printf '%s' '-'
    return 0
  fi
  jq -r 'keys[0] // "-"' "$1" 2>/dev/null || printf '%s' '-'
}

# One-line human summary for a verdict name.
pc_verdict_summary() { # verdict-name
  case "$1" in
    inSync) printf '%s' 'in sync — the code satisfies its spec' ;;
    specViolation) printf '%s' 'SPEC VIOLATION — one or more requirements are refuted' ;;
    verificationError) printf '%s' 'VERIFICATION ERROR — the project did not verify cleanly' ;;
    *) printf '%s' 'no sync has run yet — run: predictable sync' ;;
  esac
}

pc_read_event() { # captured-stdin-file
  if ! pc_have_jq; then
    printf '%s' '-'
    return 0
  fi
  jq -r '.hook_event_name // .hookEventName // "-"' "$1" 2>/dev/null || printf '%s' '-'
}

# --- JSON control-output emitters (Claude/Codex share these shapes) ----------

# additionalContext injection (SessionStart/UserPromptSubmit/PreCompact/Stop/…).
pc_emit_context() { # event context
  pc_have_jq || return 0
  jq -n --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

# A user-visible advisory that is NOT model context (bootstrap failures, etc.).
pc_emit_system_message() { # message
  pc_have_jq || {
    printf '%s\n' "$1" >&2
    return 0
  }
  jq -n --arg m "$1" '{systemMessage: $m}'
}

# PreToolUse deny decision.
pc_emit_deny() { # reason
  pc_have_jq || return 0
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}
