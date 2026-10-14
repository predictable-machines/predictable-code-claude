#!/usr/bin/env sh
# shellcheck shell=sh
#
# Test stub for the `predictable` CLI. Lets the L1 hook-contract tests exercise
# the scripts with no runtime bundle and no LLM: `sync --json` prints the
# SyncResponse fixture named by $STUB_VERDICT (default: inSync). $STUB_FAIL=1
# makes it exit non-zero to drive the gate's infra-error path. $STUB_STDERR names a
# file written to stderr as the real CLI writes its progress stream and refusals, and
# $STUB_EXIT then exits with that code and NOTHING on stdout — how the CLI refuses a
# checkout (exit 1, one line on stderr).

case "$1" in
  --version)
    echo "predictable (stub) 0.0.0"
    exit 0
    ;;
  fix-check)
    # `fix-check --json`: the fix gate's question. $STUB_FIXCHECK names the answer to print
    # (default: gone); $STUB_FAIL=1 is a check that could not run.
    if [ "${STUB_FAIL:-}" = "1" ]; then
      echo "stub: simulated fix-check failure" >&2
      exit 1
    fi
    if [ -n "${STUB_FIXCHECK:-}" ] && [ -f "$STUB_FIXCHECK" ]; then
      cat "$STUB_FIXCHECK"
    else
      printf '{"verdict":"gone","reason":"no longer reported","codeDigest":"d0","introduced":[]}\n'
    fi
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

if [ -n "${STUB_STDERR:-}" ] && [ -f "$STUB_STDERR" ]; then
  cat "$STUB_STDERR" >&2
fi
if [ -n "${STUB_EXIT:-}" ]; then
  exit "$STUB_EXIT"
fi

if [ -n "${STUB_VERDICT:-}" ] && [ -f "$STUB_VERDICT" ]; then
  cat "$STUB_VERDICT"
else
  printf '{"inSync":{"requirementsRefuted":0}}\n'
fi
exit 0
