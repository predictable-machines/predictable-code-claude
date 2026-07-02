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
}

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
[ "$CODE" -eq 2 ]
check "git push + verificationError -> exit 2" $? "got exit $CODE"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny'
check "git push + inSync -> allow (exit 0, no deny)" $? "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-bash-noop.json
[ "$CODE" -eq 0 ] && [ -z "$OUT" ]
check "non-git Bash -> passthrough (exit 0, no output)" $? "exit $CODE out=$OUT"

fresh_data
STUB_FAIL=1 run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'deny'
check "git push + sync infra error -> allow + systemMessage (never trap)" $? "exit $CODE out=$OUT"

echo "== sync-run =="

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ]
check "PostToolUse(Write) clean -> exit 0, verdict persisted" $? "exit $CODE"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'SPEC VIOLATION'
check "PostToolUse(Write) regression -> surfaces verdict in additionalContext" $? "exit $CODE out=$OUT"

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

fresh_data
unset PREDICTABLE_DIST_TOKEN
run_hook bootstrap.sh session-start.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && contains "$OUT" 'PREDICTABLE_DIST_TOKEN'
check "SessionStart, no token -> clean systemMessage, exit 0" $? "exit $CODE out=$OUT"
# Privacy: a failure path must NEVER mention Predictable source paths/packages.
! contains "$OUT" 'packages/Predictable' && ! contains "$OUT" '.lean'
check "bootstrap failure output leaks no source" $? "out=$OUT"

echo "== side effects =="
[ -f "$DATA/hook-events.log" ]
check "hook-events.log written" $? "expected $DATA/hook-events.log"

echo
printf 'L1: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
