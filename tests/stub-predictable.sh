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
  init)
    # Mirror the real headless init: write project.json so pc_ensure_init sees the
    # project as configured afterward. STUB_FAIL simulates an init that can't run.
    if [ "${STUB_FAIL:-}" = "1" ]; then
      echo "stub: simulated init failure" >&2
      exit 1
    fi
    mkdir -p .predictable-code 2>/dev/null || true
    printf '{"name":"stub"}\n' >.predictable-code/project.json
    echo "Initialized (stub)"
    exit 0
    ;;
esac

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
