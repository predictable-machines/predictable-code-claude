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

# `predictable init` writes `<project>/.predictable-code/project.json`. Until it
# exists, `predictable sync` drops into an INTERACTIVE setup wizard (engine/mode
# picker) that ignores `--json` and would hang a non-TTY hook — so every hook
# that runs `sync` must guard on this and skip when the project isn't set up.
pc_config_file() { printf '%s/.predictable-code/project.json' "$(pc_project_dir)"; }
pc_is_configured() { [ -f "$(pc_config_file)" ]; }

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

# PreToolUse allow decision — auto-approves a tool call so the host skips its
# permission prompt. Used to silently approve the plugin's OWN `predictable sync`
# (scoped tightly; everything else falls through to the host's normal flow).
pc_emit_allow() { # reason
  pc_have_jq || return 0
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: $r}}'
}

# --- Session progress metric (branding: issues found vs fixed) ---------------
#
# Every sync appends one record here so status-context and the Stop hook can
# report "Predictable found N issues; Claude fixed M this session" — the
# ground-truth story that Predictable made Claude's code better. One JSON object
# per line; reset per session (status-context truncates it on SessionStart:startup).
pc_session_history_file() { printf '%s/session-history.jsonl' "$(pc_data_dir)"; }

pc_reset_session_history() { rm -f "$(pc_session_history_file)" 2>/dev/null || true; }

# Actionable-issue count for a SyncResponse file, keyed on its verdict. Reads
# the REAL result fields emitted by `sync --json` (Core.SpecSync.SyncResponse);
# missing fields degrade to 0. verificationError = real build errors + refuted
# contracts (counterexamples); inSync = residual refuted/violated (normally 0);
# specViolation = best-effort from its report (future scaffolding — not yet
# produced by the pipeline); inferSpecs/noCode are not "issues".
pc_issue_count() { # verdict-file
  if [ ! -f "$1" ] || ! pc_have_jq; then
    printf '0'
    return 0
  fi
  jq -r '
    (keys[0]) as $v | (.[$v]) as $r
    | if   $v == "inSync"            then (($r.theoremsRefuted // 0) + ($r.requirementsViolated // 0) + ($r.guidelinesViolated // 0))
      elif $v == "verificationError" then (($r.realErrorCount // 0) + ($r.counterexampleCount // 0))
      elif $v == "specViolation"     then (($r.report.refutedCount) // (($r.report.violations // []) | length))
      else 0 end
  ' "$1" 2>/dev/null || printf '0'
}

# Append one sync to the session history: {ts, event, verdict, issues}.
pc_record_sync() { # event verdict-file
  pc_have_jq || return 0
  _pc_hist="$(pc_session_history_file)"
  mkdir -p "$(pc_data_dir)" 2>/dev/null || true
  _pc_vd="$(pc_verdict_name "$2")"
  _pc_iss="$(pc_issue_count "$2")"
  jq -nc --arg ts "$(pc_now)" --arg ev "$1" --arg vd "$_pc_vd" --argjson iss "${_pc_iss:-0}" \
    '{ts: $ts, event: $ev, verdict: $vd, issues: $iss}' >>"$_pc_hist" 2>/dev/null || true
}

# Branded one-line summary of the session so far, computed from the history.
# Empty when nothing has run yet (caller supplies the fallback). Headlines the
# peak issue count (the worst point, ~ the initial generation) and how many
# Claude has since resolved — the closing "proven in sync" line when it lands.
pc_session_summary() {
  _pc_hist="$(pc_session_history_file)"
  { [ -f "$_pc_hist" ] && pc_have_jq; } || {
    printf ''
    return 0
  }
  jq -rs '
    if length == 0 then "" else
      (map(.issues) | max) as $peak
      | (last.issues) as $cur
      | (last.verdict) as $vd
      | length as $iters
      | ([.[] | select(.event == "sync-gate" and .verdict != "inSync")] | length) as $gate
      | ($peak - $cur) as $fixed
      | (if $vd == "inSync" and $peak > 0 then
           "✓ Proven in sync — Predictable surfaced \($peak) issue(s) in the code this session; Claude fixed all \($peak) over \($iters) sync(s). Every checked requirement is now proven against its spec."
         elif $vd == "inSync" then
           "✓ Proven in sync — Predictable verified the code against its spec (\($iters) sync(s), no issues found)."
         elif $vd == "inferSpecs" then
           "Predictable: source found but no specs yet — verification is idle until specs exist."
         elif $vd == "noCode" then
           "Predictable: no source code detected to verify."
         elif $fixed > 0 then
           "Predictable: \($fixed) of \($peak) issue(s) fixed so far, \($cur) remaining, over \($iters) sync(s) — keep fixing until inSync."
         else
           "Predictable: \($cur) issue(s) open (\($iters) sync(s)). See verification/.analysis-results.json."
         end)
      + (if $gate > 0 then " · gate blocked \($gate) push(es) while out of sync." else "" end)
    end
  ' "$_pc_hist" 2>/dev/null || printf ''
}
