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
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
contains "$OUT" '"permissionDecision": "deny"'
check "git push + verificationError -> deny JSON" $?
rc=1
[ "$CODE" -eq 2 ] && rc=0
check "git push + verificationError -> exit 2" "$rc" "got exit $CODE"

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

echo "== sync-run =="

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && contains "$OUT" 'Proven in sync'
check "PostToolUse(Write) clean -> exit 0, verdict persisted, summary emitted" $? "exit $CODE out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'issue'
check "PostToolUse(Write) with open issues -> summary in additionalContext" $? "exit $CODE out=$OUT"

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
contains "$OUT" 'no sync' && [ ! -f "$DATA/session-history.jsonl" ]
check "SessionStart:startup resets the session tally" $? "out=$OUT"

echo "== status-context =="

fresh_data
cp "$ROOT/fixtures/verdict-specViolation.json" "$DATA/last-verdict.json"
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'additionalContext' && contains "$OUT" 'SPEC VIOLATION'
check "UserPromptSubmit with stored verdict -> additionalContext" $? "exit $CODE out=$OUT"

fresh_data
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'no sync'
check "UserPromptSubmit with no verdict -> 'no sync yet' context" $? "exit $CODE out=$OUT"

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

echo "== not-configured guard (no setup wizard, no hang) =="

fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
rc=1
[ "$CODE" -eq 0 ] && contains "$OUT" 'not set up' && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "sync-run unconfigured -> skips sync, advises setup" "$rc" "exit $CODE out=$OUT"

fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny' && rc=0
check "sync-gate unconfigured -> allows (no gate, no hang)" "$rc" "exit $CODE out=$OUT"

fresh_data
unconfigure
run_hook status-context.sh user-prompt-submit.json
contains "$OUT" 'not set up'
check "status-context unconfigured -> advises setup" $?

echo "== side effects =="
rc=1
[ -f "$DATA/hook-events.log" ] && rc=0
check "hook-events.log written" "$rc" "expected $DATA/hook-events.log"

echo
printf 'L1: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
