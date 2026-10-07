#!/usr/bin/env bash
# L1 hook-contract tests (the plan's fast, deterministic, no-LLM, no-bundle
# gate). Pipes captured stdin fixtures into each hook script and asserts the
# stdout JSON, exit code, side effects (hook-events.log, last-verdict), and — for
# bootstrap — that a failure path never leaks source.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
STUB="$ROOT/tests/stub-predictable.sh"
chmod +x "$ROOT"/scripts/*.sh "$ROOT"/bin/predictable "$STUB" 2>/dev/null || true

pass=0
fail=0
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

fresh_data() {
  # A `VAR=x run_hook …` prefix on a FUNCTION call persists in the shell after
  # it returns, so a stub knob set by one test silently governed every later one
  # — a `STUB_FAIL=1` four tests up turned a deny case into an infra-error
  # allow, and the test read as a broken gate rather than a leaked variable.
  unset STUB_FAIL STUB_VERDICT STUB_SESSION_OUT PREDICTABLE_SESSION_ID
  DATA=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$DATA"
  PROJ=$(mktemp -d)
  export CLAUDE_PROJECT_DIR="$PROJ"
  # Default to a CONFIGURED project so sync-running tests exercise the sync path.
  # A test that wants the unconfigured path calls unconfigure.
  mkdir -p "$PROJ/.predictable-code"
  printf '{}' >"$PROJ/.predictable-code/project.json"
}

unconfigure() { rm -f "$CLAUDE_PROJECT_DIR/.predictable-code/project.json"; }

# Run a hook script with a fixture on stdin. Sets OUT/CODE.
run_hook() { # script fixture
  OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PREDICTABLE_BIN="$STUB" \
    "$ROOT/scripts/$1" <"$ROOT/fixtures/$2" 2>"$ERRFILE")
  CODE=$?
}

check() { # description condition-result(0=ok)
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1))
    printf '  ok   — %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL — %s\n' "$1"
    [ -n "${3:-}" ] && printf '         %s\n' "$3"
  fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/bin/predictable; then
    check "shellcheck clean" 0
  else
    check "shellcheck clean" 1 "shellcheck reported issues (see above)"
  fi
else
  printf '  skip — shellcheck not installed\n'
fi

echo "== sync-gate =="

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
contains "$OUT" '"permissionDecision": "deny"'
check "git push + specViolation -> deny JSON" $?
rc=1
[ "$CODE" -eq 2 ] && rc=0
check "git push + specViolation -> exit 2" "$rc" "got exit $CODE"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'deny' && rc=0
check "git push + verificationError -> advisory allow (no block)" "$rc" "exit $CODE out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny'
check "git push + inSync -> allow (exit 0, no deny)" $? "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-bash-noop.json
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "non-git Bash -> passthrough (exit 0, no output)" "$rc" "exit $CODE out=$OUT"

fresh_data
STUB_FAIL=1 run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'deny'
check "git push + sync infra error -> allow + systemMessage (never trap)" $? "exit $CODE out=$OUT"

# git's global options sit between the program and its subcommand, so a glob
# needing the two words adjacent never matched these — the gate ran, looked
# healthy, and let them through. Caught by checking HEAD, not by the gate.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-commit-options.json
rc=1
[ "$CODE" -eq 2 ] && contains "$OUT" '"permissionDecision": "deny"' && rc=0
check "git -c … commit + specViolation -> deny (options do not hide the subcommand)" "$rc" "exit $CODE out=$OUT"

# Publishing is decided before auto-approval, or the second half of the line
# would be a way around the gate.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-push-ridealong.json
rc=1
[ "$CODE" -eq 2 ] && contains "$OUT" '"permissionDecision": "deny"' && rc=0
check "git push && predictable sync -> deny (no ride-along approval)" "$rc" "exit $CODE out=$OUT"

# A read-only git command that merely contains the word must not run a check.
fresh_data
run_hook sync-gate.sh pre-tool-use-git-log.json
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "git log --grep=commit -> passthrough (no check)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-predictable-sync.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable sync -> auto-allow (no permission prompt)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-predictable-init.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable init -> auto-allow (setup runs without prompt)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-report-link.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "the report's Control Center link -> auto-allow (opens without prompt)" "$rc" "exit $CODE out=$OUT"

# The link script carries only ITSELF: named inside another command it approves nothing.
fresh_data
run_hook sync-gate.sh pre-tool-use-report-link-smuggled.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" '"permissionDecision": "allow"' && rc=0
check "a command merely naming the link script -> NOT auto-allowed" "$rc" "exit $CODE out=$OUT"

# `predictable serve` is a deleted verb: nothing auto-approves it any more.
fresh_data
run_hook sync-gate.sh pre-tool-use-serve.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" '"permissionDecision": "allow"' && rc=0
check "predictable serve (deleted) -> NOT auto-allowed" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-agent-verify.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable specs requirements agent-verify -> auto-allow (records reviewed fix)" "$rc" "exit $CODE out=$OUT"

echo "== progress formatter (#1237 NDJSON -> friendly lines) =="

if command -v jq >/dev/null 2>&1; then
  PROG_OUT=$(printf '%s\n' \
    '{"v":1,"event":"phase","phase":"translation","state":"start","files":42}' \
    'a schema-drift warning, not json' \
    '{"v":1,"event":"phase","phase":"analysis","state":"done","functions":30,"findings":7}' \
    '{"v":1,"event":"phase","phase":"inference","state":"done"}' \
    | jq --unbuffered -jR -f "$ROOT/scripts/progress.jq" 2>/dev/null)
  rc=1
  contains "$PROG_OUT" 'Reading your code' \
    && contains "$PROG_OUT" 'Analyzed 30 function(s) — 7 potential issue(s)' \
    && contains "$PROG_OUT" 'Specification inferred' \
    && ! contains "$PROG_OUT" 'not json' \
    && rc=0
  check "progress.jq maps phase events to domain lines, drops non-JSON" "$rc" "out=$PROG_OUT"
else
  check "progress.jq (skipped — jq not installed)" 0 ""
fi

echo "== sync-run =="

# A non-Stop event exercises emit_advisory's additionalContext fallback branch.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && contains "$OUT" 'Proven in sync'
check "sync-run clean -> exit 0, verdict persisted, summary emitted" $? "exit $CODE out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'issue'
check "sync-run with open issues -> summary in additionalContext (fallback)" $? "exit $CODE out=$OUT"

echo "== metric: issues found -> fixed (branding) =="

fresh_data
# Iteration 1: verificationError = 3 issues (1 real + 2 refuted).
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
contains "$OUT" 'issue' && ! contains "$OUT" 'Proven'
check "iter1 (verificationError) -> reports open issues" $? "out=$OUT"

# Iteration 2 at Stop: inSync = 0 issues -> closing summary crediting the fixes.
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
contains "$OUT" 'Proven in sync' && contains "$OUT" 'fixed all 3'
check "iter2 (inSync) -> closing summary reports 3 issues fixed" $? "out=$OUT"

run_hook status-context.sh user-prompt-submit.json
contains "$OUT" 'Proven in sync' && contains "$OUT" 'fixed all 3'
check "status-context surfaces the same session summary" $? "out=$OUT"

hist_lines=$(wc -l <"$DATA/session-history.jsonl" 2>/dev/null | tr -d ' ')
rc=1
[ "$hist_lines" = "2" ] && rc=0
check "session-history recorded 2 syncs" "$rc" "history=$(cat "$DATA/session-history.jsonl" 2>/dev/null)"

# A fresh session (SessionStart:startup) resets the tally for the next run.
run_hook status-context.sh session-start.json
contains "$OUT" 'no check' && [ ! -f "$DATA/session-history.jsonl" ]
check "SessionStart:startup resets the session tally" $? "out=$OUT"

echo "== session-sync (SessionStart fires 'sync --json --claude' detached) =="

# startup + git repo -> fires the first sync (--claude auto-inits product-side),
# persists verdict. No config check in the hook.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null || true
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start.json
rc=1
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart(startup)+git -> fires sync, persists verdict" "$rc" "exit $CODE"

# resume source -> no-op (state already exists; don't re-sync).
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null || true
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start-resume.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart(resume) -> no-op (no sync)" "$rc" "verdict=$([ -f "$DATA/last-verdict.json" ] && echo yes || echo no)"

# not a git repo -> never scaffold.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart non-git dir -> no-op (never scaffold)" "$rc" "verdict=$([ -f "$DATA/last-verdict.json" ] && echo yes || echo no)"

echo "== metric counts analysis findings =="

# pc_issue_count, with no `findingsTotal` in the verdict, counts the analysis results'
# findings — reachable-now AND potential — over the verdict counters (inSync would
# otherwise count 0).
fresh_data
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/verification"
printf '{"findingsAffecting": 7, "findingsPotential": 3}' \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/verification/.analysis-results.json"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "10" ] && rc=0
check "metric counts affecting + potential findings (10), not the inSync verdict (0)" "$rc" "issues=$iss"

# And the sync's own `findingsTotal` wins when the verdict carries one: it is the number the
# Control Center shows for the same analysis. Measured: "5 issue(s) open" from
# `findingsAffecting` alone, over an analysis listing 63.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "63" ] && rc=0
check "metric counts the sync's findingsTotal (63)" "$rc" "issues=$iss"

# The ENVELOPE `sync --json` writes today carries the verdict under `.result`, with `findings`
# as its first key: read as the bare shape it found no count and summed another denominator
# (measured: 911 beside a status line saying 48).
fresh_data
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/verification"
printf '{"findingsAffecting": 600, "findingsPotential": 311}' \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/verification/.analysis-results.json"
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical-envelope.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "48" ] && rc=0
check "metric reads findingsTotal out of the envelope (48), not the analysis sum (911)" "$rc" "issues=$iss"

echo "== envelope verdict parsing (#1236) =="

# pc_verdict_name reads the verdict from the new envelope (.result) and the older
# bare shape ({<verdict>:…}) alike.
fresh_data
printf '{"schemaVersion":1,"result":{"mechanical":{}},"findings":[]}' >"$DATA/env.json"
printf '{"inSync":{}}' >"$DATA/bare.json"
v_env=$( . "$ROOT/scripts/lib.sh"; pc_verdict_name "$DATA/env.json" )
v_bare=$( . "$ROOT/scripts/lib.sh"; pc_verdict_name "$DATA/bare.json" )
rc=1
[ "$v_env" = "mechanical" ] && [ "$v_bare" = "inSync" ] && rc=0
check "pc_verdict_name handles envelope (.result) + bare shapes" "$rc" "env=$v_env bare=$v_bare"

echo "== the database layout =="

# In a git checkout `.predictable-code/` is the database (a worktree, its `.git` a FILE), and the
# runtime's state for the checked-out branch is that branch's entry — `feature/x` included, whose
# name holds a slash. Elsewhere it is `.predictable-code/` itself.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q -b feature/x
printf 'gitdir: /elsewhere\n' >"$CLAUDE_PROJECT_DIR/.predictable-code/.git"
state=$( . "$ROOT/scripts/lib.sh"; pc_state_dir )
rc=1
[ "$state" = "$CLAUDE_PROJECT_DIR/.predictable-code/feature/x/.predictable-code" ] && rc=0
check "pc_state_dir is the checked-out branch's entry in a database" "$rc" "state=$state"
mkdir -p "$state"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x"}' "$$" >"$state/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "a live lock in the branch's entry is a running sync" "$rc" "running=$running"
fresh_data
state=$( . "$ROOT/scripts/lib.sh"; pc_state_dir )
rc=1
[ "$state" = "$CLAUDE_PROJECT_DIR/.predictable-code" ] && rc=0
check "pc_state_dir is .predictable-code itself outside a database" "$rc" "state=$state"

echo "== concurrency guard =="

fresh_data
# Simulate an in-flight `predictable sync` (argv0 spoofed via exec -a) so the
# guard must skip rather than start a second, colliding sync. A running sync
# is detected via the runtime's project sync lock (live pid), so simulate one:
# this test shell's own pid is alive for the duration.
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x"}' "$$" \
  > "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rm -f "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/session-history.jsonl" ] \
  && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "sync already running -> skip (no second sync, logs skipped-running)" "$rc" \
  "exit $CODE hist=$([ -f "$DATA/session-history.jsonl" ] && echo yes || echo no)"

# In a database checkout the CLI takes its lock in the checked-out branch's entry, and
# the HOOK must look there: a SessionStart sync and a Stop sync 3 s apart both ran in a
# release test.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q -b main
printf 'gitdir: /elsewhere\n' >"$CLAUDE_PROJECT_DIR/.predictable-code/.git"
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/main/.predictable-code"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x", "stage": "database"}' "$$" \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/main/.predictable-code/.sync.lock"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/session-history.jsonl" ] \
  && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "a live lock in the branch's entry -> the turn-end hook starts no second sync" "$rc" \
  "exit $CODE hist=$([ -f "$DATA/session-history.jsonl" ] && echo yes || echo no)"

# The CLI creates the lock and then writes its record into it, so a hook can meet it empty
# or half-written: that is a sync starting, and starting another beside it is the race.
fresh_data
: >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "an empty lock file (being written) counts as running" "$rc" "running=$running"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ ! -f "$DATA/session-history.jsonl" ] && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "an empty lock file -> the turn-end hook starts no second sync" "$rc"

printf '{"pid": 12' >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "a half-written lock record counts as running" "$rc" "running=$running"

# ...but only briefly: an unreadable lock nobody has touched for minutes was abandoned,
# and reading it as running for ever would stop every hook from syncing again.
: >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
touch -t 200001010000 "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "no" ] && rc=0
check "an empty lock file left for long is not a running sync" "$rc" "running=$running"

# A lock naming a pid that is gone is stale (the CLI clears it on its next acquire).
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf '{"pid": %s, "runId": "gone", "inputsDigest": "x"}' "$dead_pid" \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "no" ] && rc=0
check "a lock naming a dead pid is not a running sync" "$rc" "running=$running pid=$dead_pid"

echo "== status-context =="

fresh_data
cp "$ROOT/fixtures/verdict-specViolation.json" "$DATA/last-verdict.json"
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'additionalContext' && contains "$OUT" 'SPEC VIOLATION'
check "UserPromptSubmit with stored verdict -> additionalContext" $? "exit $CODE out=$OUT"

fresh_data
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'no check'
check "UserPromptSubmit with no verdict -> 'no check yet' context" $? "exit $CODE out=$OUT"

echo "== session =="
# Every sync a hook starts names the session it runs for, so the Control Center
# keeps one run per session rather than a row per turn-end check.
fresh_data
SESSION_OUT=$(mktemp)
STUB_SESSION_OUT="$SESSION_OUT" STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  PREDICTABLE_SYNC_FOREGROUND=1 run_hook sync-run.sh stop.json
GOT_SESSION=$(cat "$SESSION_OUT")
contains "<$GOT_SESSION>" "<fixture-session>"
check "a turn-end sync carries the hook's session_id as PREDICTABLE_SESSION_ID" $? "got=$GOT_SESSION"
rm -f "$SESSION_OUT"
unset STUB_SESSION_OUT

echo "== bootstrap =="

# Dev fallback: a `predictable` on PATH + no token -> stay quiet (no nag).
fresh_data
fakebin=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' >"$fakebin/predictable"
chmod +x "$fakebin/predictable"
unset PREDICTABLE_DIST_TOKEN
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$fakebin:$PATH" "$ROOT/scripts/bootstrap.sh" <"$ROOT/fixtures/session-start.json" 2>"$ERRFILE")
CODE=$?
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "predictable on PATH, no token -> quiet (no nag)" "$rc" "exit $CODE out=$OUT"

# Nothing usable: no token, no predictable, no bundle -> clean advisory, no leak.
fresh_data
unset PREDICTABLE_DIST_TOKEN
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/scripts/bootstrap.sh" <"$ROOT/fixtures/session-start.json" 2>"$ERRFILE")
CODE=$?
rc=1
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'packages/Predictable' && ! contains "$OUT" '.lean' && rc=0
check "no token/predictable/bundle -> advisory, exit 0, no leak" "$rc" "exit $CODE out=$OUT"

echo "== no config gate (scripts just run 'sync --json --claude'; product auto-inits) =="

# The plugin never checks config — it runs `sync --json --claude` and the PRODUCT
# auto-initializes if needed. So even unconfigured, the hook runs sync + records a
# verdict (the stub just prints one; it doesn't init — that's the product's job).
fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
rc=1
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && rc=0
check "sync-run unconfigured -> still runs sync (no config gate)" "$rc" "exit $CODE out=$OUT"

# The gate likewise runs sync unconditionally (inSync -> allow).
fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny' && rc=0
check "sync-gate unconfigured -> runs sync, allows on inSync" "$rc" "exit $CODE out=$OUT"

# status-context is read-only: it never runs sync; it advises that setup is automatic.
fresh_data
unconfigure
run_hook status-context.sh user-prompt-submit.json
contains "$OUT" 'set up'
check "status-context unconfigured -> advisory (auto-configures)" $?

echo "== side effects =="
rc=1
[ -f "$DATA/hook-events.log" ] && rc=0
check "hook-events.log written" "$rc" "expected $DATA/hook-events.log"

echo
printf 'L1: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
