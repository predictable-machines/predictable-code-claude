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
run_hook sync-gate.sh pre-tool-use-specs-view.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable specs view -> auto-allow (viewer opens without prompt)" "$rc" "exit $CODE out=$OUT"

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

# pc_issue_count prefers findingsAffecting from the project's analysis results over
# the verdict counters (inSync would otherwise count 0).
fresh_data
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/verification"
printf '{"findingsAffecting": 7, "findingsPotential": 3}' \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/verification/.analysis-results.json"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "7" ] && rc=0
check "metric counts analysis findingsAffecting (7), not the inSync verdict (0)" "$rc" "issues=$iss"

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
