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

# --- Reading a command line well enough to gate it ------------------------
#
# A glob is not good enough, and it fails in the worst direction: silently, and
# towards letting things through. `*"git commit"*` needs the two words adjacent,
# but git's global options sit between the program and its subcommand, so
# `git -c user.email=… commit`, `git -C /repo push` and `git --no-pager commit`
# never matched — the gate ran, looked healthy, and waved them past. Found by
# checking that HEAD had not moved, not by anything the gate itself said.
#
# Two rules do it properly. Segment first, because `git push && predictable sync`
# is a push with a Predictable command attached and must not be auto-approved on
# its second half. Then walk tokens the way git does, skipping the global options
# — including the ones that consume the NEXT token as their value.

# Split a command line into independently-executed pieces, one per line.
# Separators and the grouping characters that would hide a command from a token
# walk (`$(`, backticks, parens) all become boundaries, so `$(git push)` reads as
# its own segment rather than as an opaque argument to `echo`.
pc_segments() { # command
  # shellcheck disable=SC2016  # `$(` here is literal text being replaced, not an expansion.
  # The trailing newline matters: `read` returns false at EOF, so a line without
  # one is never seen by a `while read` loop — a single-segment `git commit`
  # silently produced no segments at all.
  printf '%s\n' "$1" |
    sed -e 's/\$(/;/g' -e 's/[()`]/;/g' -e 's/&&/;/g' -e 's/||/;/g' -e 's/[|&]/;/g' |
    tr ';' '\n'
}

# The git subcommand one segment runs, or empty when it does not run git.
# Skips leading VAR=value assignments and wrappers (env, sudo, …), then git's
# own global options; `-c`, `-C`, `--git-dir`, `--work-tree`, `--namespace`,
# `--exec-path` and `--config-env` swallow the token after them.
pc_git_subcommand() { # segment
  awk '
    function base(p) { sub(/^.*\//, "", p); return p }
    {
      i = 1
      while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
             base($i) == "env" || base($i) == "sudo" || base($i) == "command" ||
             base($i) == "nice" || base($i) == "time")) i++
      if (i > NF || base($i) != "git") exit
      i++
      while (i <= NF) {
        t = $i
        if (substr(t, 1, 1) != "-") { print t; exit }
        if (t == "-c" || t == "-C" || t == "--git-dir" || t == "--work-tree" ||
            t == "--namespace" || t == "--exec-path" || t == "--config-env") i += 2
        else i += 1
      }
    }
  ' <<EOF
$1
EOF
}

# True when any segment runs one of the publishing subcommands.
pc_publishes() { # command
  pc_segments "$1" | while IFS= read -r _pc_seg; do
    case " $(pc_git_subcommand "$_pc_seg") " in
      " push " | " commit ") printf 'yes' ;;
    esac
  done | grep -q yes
}

# True when EVERY segment runs one of Predictable's own verbs. Every, not any:
# `git push && predictable sync` must not be approved on its second half.
pc_is_own_command() { # command
  _pc_any=0
  _pc_all=1
  while IFS= read -r _pc_seg; do
    [ -n "$_pc_seg" ] || continue
    _pc_any=1
    # The report command's link script, and ONLY as the whole segment: a script path
    # merely mentioned inside another command must not carry that command through.
    _pc_trim=$(printf '%s' "$_pc_seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # The first two spellings are the command TEXT the agent runs, unexpanded, so the
    # `${…}` in them is literal on purpose.
    # shellcheck disable=SC2016
    case "$_pc_trim" in
      '"${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh"' | \
        '${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh' | \
        "\"${CLAUDE_PLUGIN_ROOT:-/nonexistent}/scripts/control-center-url.sh\"" | \
        "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/scripts/control-center-url.sh") continue ;;
    esac
    case "$_pc_seg" in
      *predictable*) ;;
      *) _pc_all=0; continue ;;
    esac
    case "$_pc_seg" in
      *" sync"* | *" init"* | *agent-verify* | *" settings"* | *" project"* | *" open"*) ;;
      *) _pc_all=0 ;;
    esac
  done <<EOF
$(pc_segments "$1")
EOF
  [ "$_pc_any" -eq 1 ] && [ "$_pc_all" -eq 1 ]
}

pc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

pc_have_jq() { command -v jq >/dev/null 2>&1; }

# The host session this hook runs for, exported as PREDICTABLE_SESSION_ID so a
# signed-in `predictable sync` reports every check of one session as ONE run in
# the Control Center instead of a row per check. These hooks sync at session
# start, at every turn end and before every commit or push, so one session is
# many syncs. Read from the hook's own `session_id` rather than trusting that the
# host put its session in the environment; a value already set wins. Never fails:
# no jq or no id simply leaves the variable unset.
pc_export_session() { # stdin-json-file
  [ -n "${PREDICTABLE_SESSION_ID:-}" ] && return 0
  pc_have_jq || return 0
  pc_session_id="$(jq -r '.session_id // ""' "$1" 2>/dev/null || printf '')"
  if [ -n "$pc_session_id" ]; then
    PREDICTABLE_SESSION_ID="$pc_session_id"
    export PREDICTABLE_SESSION_ID
  fi
  return 0
}

# `predictable sync --claude` auto-initializes the project (Claude defaults + source
# detection) when it isn't set up yet, so the plugin never has to init itself — it
# just always runs `sync --json --claude`. `pc_is_configured` is used only for
# read-only status messaging (status-context), never as a gate on running sync.
pc_config_file() { printf '%s/.predictable-code/project.json' "$(pc_project_dir)"; }

# The checked-out branch's STATE DIRECTORY, where the runtime keeps its lock, its
# last verdict, the datasets and the analysis results. In a git checkout
# `.predictable-code/` is the DATABASE — a worktree of the `predictable-code-database`
# branch, whose `.git` is a FILE — and each branch's state is its entry in it
# (`<db>/<branch>/.predictable-code`, a detached HEAD's under `.detached`); anywhere
# else it is `.predictable-code/` itself. `project.json` is at the database's root
# either way, which is why `pc_config_file` needs none of this.
pc_state_dir() {
  _pc_db="$(pc_project_dir)/.predictable-code"
  if [ -f "$_pc_db/.git" ]; then
    _pc_branch="$(git -C "$(pc_project_dir)" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '.detached')"
    printf '%s/%s/.predictable-code' "$_pc_db" "$_pc_branch"
  else
    printf '%s' "$_pc_db"
  fi
}
pc_is_configured() { [ -f "$(pc_config_file)" ]; }

# The runtime's project sync lock: in the checked-out branch's state directory, the
# same place the CLI takes it (`<basePath>/.sync.lock`).
pc_sync_lock_file() { printf '%s/.sync.lock' "$(pc_state_dir)"; }

# The pid a lock record names, or nothing when the record cannot be read. The CLI
# CREATES the lock file and only then writes its record into it, so a reader can meet
# an empty or half-written file — a sync starting, not a lock nobody holds.
pc_lock_pid() { # lock-file
  jq -r 'if type == "object" and (.pid | type) == "number" then .pid else empty end' \
    "$1" 2>/dev/null
}

# Seconds since a file last changed, or nothing when `stat` cannot say. GNU's spelling
# goes first: BSD `stat` rejects `-c` outright, while GNU `stat` reads `-f %m` as "the
# file-system status of a file named %m" and prints the real file's status as well,
# which would land in the number.
pc_file_age() { # file
  _pc_mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)"
  case "$_pc_mtime" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$(($(date +%s) - _pc_mtime))"
}

# How long a lock that cannot be read still counts as a sync starting. The CLI gives a
# writer two seconds before it reads such a lock as gone; a hook starts slower than the
# CLI's own retry loop, so it allows longer before it calls one abandoned.
pc_unreadable_lock_grace_seconds=10

# True when another `predictable … sync` is already running anywhere on this box:
# the skill's own foreground `predictable sync --json` and any sibling Stop/
# SubagentStop hook both match. Callers skip launching a second one — two syncs on
# the same project race the engine's setup-progress watcher into a runaway (multi-GB
# stdout / pegged CPU). The pattern needs a literal space before `sync` so it hits
# `predictable sync` / `…/predictable sync` / the test stub `…predictable.sh sync`,
# but not the hook scripts' own `…/sync-run.sh` paths (no space there).
# A sync is running for THIS project iff the runtime's project sync lock
# (`.sync.lock` in the branch's state directory) names a LIVE pid — the product's own
# single-sync protocol, so the check is exact and project-scoped. The previous
# `pgrep -f 'predictable[^ ]* sync'` matched any process whose full command
# line contained those words (observed live: a leaked watcher shell from an
# unrelated agent session self-matched forever), which made every hook skip —
# no session-start sync, no toast, no statusline wiring — until reboot.
# Without jq, lock presence alone counts; a stale lock (dead pid) is cleared
# by the runtime itself on its next acquire, so a false "running" self-heals.
# A lock that cannot be read counts as running while it is young enough to be
# mid-write (`pc_unreadable_lock_grace_seconds`): two hooks each starting a sync in
# that instant is exactly the race the lock exists to stop. An age nobody can tell
# counts as running, like a lock read without jq.
pc_sync_running() {
  _pc_lock="$(pc_sync_lock_file)"
  [ -f "$_pc_lock" ] || return 1
  pc_have_jq || return 0
  _pc_lock_pid="$(pc_lock_pid "$_pc_lock")"
  case "$_pc_lock_pid" in
    '' | *[!0-9]*)
      _pc_lock_age="$(pc_file_age "$_pc_lock")"
      [ -z "$_pc_lock_age" ] && return 0
      [ "$_pc_lock_age" -le "$pc_unreadable_lock_grace_seconds" ]
      return $?
      ;;
  esac
  [ "$_pc_lock_pid" -gt 0 ] && kill -0 "$_pc_lock_pid" 2>/dev/null
}

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

# The SMT analysis results the engine writes into the project. `findingsAffecting`
# here (the reachable-now caught faults) is the ground-truth issue count — the
# verdict counters miss it entirely under `mechanical` (proving off by default).
pc_analysis_results_file() {
  printf '%s/verification/.analysis-results.json' "$(pc_state_dir)"
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

# Actionable-issue count for a sync. PREFERS the sync's own `findingsTotal` — the
# number the Control Center shows for the same analysis — then the analysis
# results' findings, REACHABLE-NOW AND POTENTIAL both: a finding whose callers were
# not established is reported, not clean, and counting `findingsAffecting` alone
# told the agent "5 issues" over an analysis the Control Center listed 63 for.
# Falls back to the SyncResponse verdict counters when neither is present. Missing
# fields degrade to 0.
pc_issue_count() { # verdict-file
  if [ -f "$1" ] && pc_have_jq; then
    # The verdict lives under `.result` in the envelope `sync --json` writes (#1236), and is the
    # whole object in the older bare shape — the rule `pc_verdict_name` reads it by. Reading the
    # bare shape alone took the envelope's FIRST key (`findings`) as the verdict, found no count
    # there, and fell through to a different denominator: 911 beside a status line saying 48.
    _pc_n="$(jq -r '(.result // .) | (.[keys[0]] | objects | .findingsTotal) // empty' "$1" 2>/dev/null)"
    if [ -n "$_pc_n" ]; then
      printf '%s' "$_pc_n"
      return 0
    fi
  fi
  _pc_ar="$(pc_analysis_results_file)"
  if [ -f "$_pc_ar" ] && pc_have_jq; then
    _pc_n="$(jq -r 'if (.findingsAffecting // null) == null then empty
                    else (.findingsAffecting + (.findingsPotential // 0)) end' "$_pc_ar" 2>/dev/null)"
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
           "Predictable: \($cur) issue(s) open (\($iters) sync(s)). /predictable-code:report opens them in the Control Center."
         end)
      + (if $gate > 0 then " · gate blocked \($gate) push(es) while out of sync." else "" end)
    end
  ' "$_pc_hist" 2>/dev/null || printf ''
}
