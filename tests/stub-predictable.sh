#!/usr/bin/env sh
# shellcheck shell=sh
#
# Test stub for the `predictable` CLI. Lets the L1 hook-contract tests exercise
# the scripts with no runtime bundle and no LLM: `sync --json` prints the
# SyncResponse fixture named by $STUB_VERDICT (default: inSync). $STUB_FAIL=1
# makes it exit non-zero to drive the gate's infra-error path.

case "$1" in
  --version)
    echo "predictable (stub) 0.0.0"
    exit 0
    ;;
esac

# Record the session the hook handed the sync, for the test that checks it.
if [ -n "${STUB_SESSION_OUT:-}" ]; then
  printf '%s' "${PREDICTABLE_SESSION_ID:-}" >"$STUB_SESSION_OUT"
fi

if [ "${STUB_FAIL:-}" = "1" ]; then
  echo "stub: simulated sync failure" >&2
  exit 1
fi

if [ -n "${STUB_VERDICT:-}" ] && [ -f "$STUB_VERDICT" ]; then
  cat "$STUB_VERDICT"
else
  printf '{"inSync":{"requirementsRefuted":0}}\n'
fi
exit 0
