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

# Brand style rule, prepended to EVERY turn's additionalContext (status-context)
# so it applies session-wide, not only inside the sync skill. Bold renders in the
# chat's Markdown; the brand cyan (#87D4D1, rgb(135 212 209)) only renders in HTML
# we control (Artifacts / reports) — the terminal/IDE Markdown renderer cannot
# color inline chat text — so the cyan is scoped there.
pc_brand_style_rule() {
  printf '%s' 'Brand style (always apply): write the names "Predictable", "Predictable Machines", and "Predictable Code" in **bold** every time they appear in your replies. In any HTML you generate (Artifacts, reports), also render those names in the brand cyan #87D4D1, bold.'
}

# AskUserQuestion rule, prepended to every turn's additionalContext alongside the
# brand rule so it governs ANY question with options, not only the sync skill's
# closing prompt. The tool itself always appends an "Other" free-text choice, so
# an explicit one is a visible duplicate the user keeps hitting.
pc_askquestion_rule() {
  printf '%s' 'AskUserQuestion (always apply): never add an "Other" / "Something else" / "None of these" / free-text / "write whatever you want" option to any question — the tool ALWAYS appends its own "Other" free-text choice, so adding one is a duplicate. List only concrete, mutually-exclusive options and let the built-in "Other" cover the rest.'
}

pc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

pc_have_jq() { command -v jq >/dev/null 2>&1; }

# `predictable sync --claude` auto-initializes the project (Claude defaults + source
# detection) when it isn't set up yet, so the plugin never has to init itself — it
# just always runs `sync --json --claude`. `pc_is_configured` is used only for
# read-only status messaging (status-context), never as a gate on running sync.
pc_config_file() { printf '%s/.predictable-code/project.json' "$(pc_project_dir)"; }
pc_is_configured() { [ -f "$(pc_config_file)" ]; }

# True when another `predictable … sync` is already running anywhere on this box:
# the skill's own foreground `predictable sync --json` and any sibling Stop/
# SubagentStop hook both match. Callers skip launching a second one — two syncs on
# the same project race the engine's setup-progress watcher into a runaway (multi-GB
# stdout / pegged CPU). The pattern needs a literal space before `sync` so it hits
# `predictable sync` / `…/predictable sync` / the test stub `…predictable.sh sync`,
# but not the hook scripts' own `…/sync-run.sh` paths (no space there).
pc_sync_running() { pgrep -f 'predictable[^ ]* sync' >/dev/null 2>&1; }

# Append one audit line: `<iso8601> <event> <matcher> <verdict>`. This is the
# observable side effect the L5 integration tests assert on ("hooks fired"), so
# it is best-effort but always attempted, even when jq is missing.
#
# ALSO appends a structured JSON line to `hook-events.jsonl`. The plain-text log
# above is deliberately left byte-identical because tests assert on it; the JSON
# stream is the machine contract the Predictable Control Center consumes to show
# what an agent is doing in real time.
#
# That second stream is REQUIRED, not a nicety: Claude Code captures its own
# child processes' output, so when this plugin runs `predictable ... --json` the
# NDJSON progress never reaches a parent that spawned the agent. Measured on a
# real fix run — the agent edited the source correctly and the parent observed
# zero phases. The hook stream is the only way the inside of an agent run is
# visible.
#
# `PREDICTABLE_CC_RUN_ID` is echoed back when present: the Control Center sets it
# in the agent's environment, and without it concurrent runs cannot be told apart.
pc_log() { # event matcher verdict [message]
  _pc_data="$(pc_data_dir)"
  mkdir -p "$_pc_data" 2>/dev/null || true
  printf '%s %s %s %s\n' "$(pc_now)" "${1:-?}" "${2:--}" "${3:--}" \
    >>"$_pc_data/hook-events.log" 2>/dev/null || true
  pc_log_json "$@"
}

# Emit one JSON object per line. Hand-rolled rather than jq-dependent: `pc_log`
# must work when jq is absent (the plain-text log already guarantees that), so
# the JSON stream must not be the one thing that needs it.
pc_json_escape() { # text
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' | tr -d '\n\r'
}

pc_log_json() { # event matcher verdict [message]
  _pc_data="$(pc_data_dir)"
  _pc_run_id="${PREDICTABLE_CC_RUN_ID:-}"
  _pc_line='{"ts":"'"$(pc_now)"'"'
  _pc_line="$_pc_line"',"agent":"claude-code"'
  _pc_line="$_pc_line"',"event":"'"$(pc_json_escape "${1:-?}")"'"'
  _pc_line="$_pc_line"',"matcher":"'"$(pc_json_escape "${2:--}")"'"'
  _pc_line="$_pc_line"',"verdict":"'"$(pc_json_escape "${3:--}")"'"'
  [ -n "${4:-}" ] && _pc_line="$_pc_line"',"message":"'"$(pc_json_escape "$4")"'"'
  [ -n "$_pc_run_id" ] && _pc_line="$_pc_line"',"runId":"'"$(pc_json_escape "$_pc_run_id")"'"'
  [ -n "${CLAUDE_SESSION_ID:-}" ] && \
    _pc_line="$_pc_line"',"sessionId":"'"$(pc_json_escape "$CLAUDE_SESSION_ID")"'"'
  _pc_line="$_pc_line"'}'
  printf '%s\n' "$_pc_line" >>"$_pc_data/hook-events.jsonl" 2>/dev/null || true
}

# Where sync-run persists the last SyncResponse so status-context (and the next
# turn's UserPromptSubmit/SessionStart) can surface it without re-running sync.
pc_last_verdict_file() { printf '%s/last-verdict.json' "$(pc_data_dir)"; }

# The SMT analysis results the engine writes into the project. `findingsAffecting`
# here (the reachable-now caught faults) is the ground-truth issue count — the
# verdict counters miss it entirely under `mechanical` (proving off by default).
pc_analysis_results_file() {
  printf '%s/.predictable-code/verification/.analysis-results.json' "$(pc_project_dir)"
}

# SyncResponse is `{constructorName: {…}}`; the constructor name IS the verdict.
# Returns one of inSync|specViolation|verificationError, or '-' when
# absent/unreadable.
pc_verdict_name() { # file
  if [ ! -f "$1" ] || ! pc_have_jq; then
    printf '%s' '-'
    return 0
  fi
  # `sync --json` now emits an envelope `{schemaVersion, result:{<verdict>:…}, findings}`
  # (#1236); the verdict lives under `.result`. Fall back to the whole object for the
  # older bare `{<verdict>:…}` shape so this works with either runtime.
  jq -r '(.result // .) | keys[0] // "-"' "$1" 2>/dev/null || printf '%s' '-'
}

# One-line human summary for a verdict name.
pc_verdict_summary() { # verdict-name
  case "$1" in
    inSync) printf '%s' 'in sync — the code satisfies its spec' ;;
    mechanical) printf '%s' 'analyzed — requirements inferred and the code checked' ;;
    specViolation) printf '%s' 'SPEC VIOLATION — one or more requirements are refuted' ;;
    verificationError) printf '%s' 'could not be fully checked this run' ;;
    inferSpecs) printf '%s' 'source found, no specs yet — inference is the next step' ;;
    noCode) printf '%s' 'no source code detected to check' ;;
    *) printf '%s' 'no check has run yet — run: predictable sync' ;;
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

# additionalContext injection. Valid ONLY for events that accept
# hookSpecificOutput.additionalContext (SessionStart / UserPromptSubmit /
# PostToolUse / PreCompact). Stop/SubagentStop do NOT — use pc_emit_system_message.
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

# Actionable-issue count for a sync. PREFERS the SMT analysis findings — the real
# caught faults (`findingsAffecting`, reachable-now) in the project's
# `.analysis-results.json` — because the verdict counters miss them entirely under
# `mechanical` (proving off by default). Falls back to the SyncResponse verdict
# counters when no analysis results are present. Missing fields degrade to 0.
pc_issue_count() { # verdict-file
  _pc_ar="$(pc_analysis_results_file)"
  if [ -f "$_pc_ar" ] && pc_have_jq; then
    _pc_n="$(jq -r '.findingsAffecting // empty' "$_pc_ar" 2>/dev/null)"
    if [ -n "$_pc_n" ]; then
      printf '%s' "$_pc_n"
      return 0
    fi
  fi
  # Fallback: derive from the SyncResponse verdict counters. inSync = residual
  # refuted/violated (normally 0); verificationError = real errors + counter-
  # examples; specViolation = best-effort from its report; others are not "issues".
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
