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

# Gate the version-control commands that publish work; auto-approve the plugin's
# OWN `predictable sync` so the agent never hits a permission prompt for it; let
# everything else fall through to the host's normal permission flow.
case "$cmd" in
  *"git push"* | *"git commit"*) ;; # fall through to the gate logic below
  *predictable*" sync"* | *predictable*" init"*)
    pc_emit_allow "Predictable Code: auto-approving the plugin's own 'predictable' setup/sync command."
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

project="$(pc_project_dir)"
bin="$(pc_predictable_bin)"
verdict_file="$(pc_last_verdict_file)"

# Can't gate a project that isn't set up — running `sync` here would launch the
# interactive setup wizard and hang. Allow the command with a notice instead of
# blocking or hanging.
if ! pc_is_configured; then
  pc_log PreToolUse sync-gate not-configured
  pc_emit_system_message "Predictable Code is not set up in this project; not gating this command. Run /predictable-code:sync to configure."
  exit 0
fi

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
