#!/usr/bin/env sh
# shellcheck shell=sh
#
# Pre-push/pre-commit gate (PreToolUse on Bash). This is the ONE place `sync`
# runs synchronously and can block: a `git push` / `git commit` is only allowed
# when the project is `inSync`.
#
# Gate discipline (see the plan's risk notes):
#   - Only DENY on a genuine non-`inSync` verdict.
#   - NEVER block on an infra error (sync couldn't run, no runtime): allow +
#     systemMessage, so a broken toolchain never traps the user.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-sync-gate.$$")
cat >"$stdin_json"

cmd="$(jq -r '.tool_input.command // .toolInput.command // ""' "$stdin_json" 2>/dev/null || echo "")"
rm -f "$stdin_json" 2>/dev/null || true

# Only gate the version-control commands that publish work. Everything else on
# the Bash tool passes straight through.
case "$cmd" in
  *"git push"* | *"git commit"*) ;;
  *)
    exit 0
    ;;
esac

project="$(pc_project_dir)"
bin="$(pc_predictable_bin)"
verdict_file="$(pc_last_verdict_file)"

tmp="$verdict_file.tmp.$$"
if ! ( cd "$project" 2>/dev/null && "$bin" sync --json ) >"$tmp" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null || true
  pc_log PreToolUse sync-gate infra-error
  pc_emit_system_message "Predictable Code: could not run \`predictable sync\` to gate this push (runtime unavailable). Allowing — verify manually."
  exit 0
fi
mv "$tmp" "$verdict_file" 2>/dev/null || true
pc_record_sync sync-gate "$verdict_file"

verdict="$(pc_verdict_name "$verdict_file")"
pc_log PreToolUse sync-gate "$verdict"

if [ "$verdict" = "inSync" ]; then
  exit 0
fi

reason="Predictable Code blocked this command: $(pc_verdict_summary "$verdict"). Fix the refuted requirement(s) (see verification/.analysis-results.json) and re-run \`predictable sync\` until it reports inSync before pushing."
# Emit the structured deny AND a stderr reason, and exit 2: whichever signal the
# host honors, the command is blocked.
pc_emit_deny "$reason"
printf '%s\n' "$reason" >&2
exit 2
