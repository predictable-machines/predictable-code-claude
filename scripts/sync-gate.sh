#!/usr/bin/env sh
# shellcheck shell=sh
#
# Pre-push/pre-commit gate (PreToolUse on Bash). This is the ONE place `sync`
# runs synchronously and can block a `git push` / `git commit`.
#
# Gate discipline (see the plan's risk notes):
#   - DENY only on a genuine refutation (`specViolation`) — a broken requirement
#     with a counterexample. Every OTHER non-`inSync` verdict (verificationError,
#     mechanical, inferSpecs, noCode) is ADVISORY: allow + systemMessage, never
#     block. Blocking on verificationError would trap every push whenever the
#     project merely couldn't be fully checked, which is not a spec breach.
#   - NEVER block when the sync did not run (no runtime, or the CLI refused the
#     checkout — one from before the database is refused until `predictable migrate`):
#     allow + systemMessage quoting the reason the CLI gave on stderr, so a broken
#     toolchain never traps the user and an unchecked push is never a silent one.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-sync-gate.$$")
cat >"$stdin_json"
pc_export_session "$stdin_json"

cmd="$(jq -r '.tool_input.command // .toolInput.command // ""' "$stdin_json" 2>/dev/null || echo "")"
rm -f "$stdin_json" 2>/dev/null || true

# Gate the version-control commands that publish work; auto-approve the plugin's
# OWN `predictable` commands so the agent never hits a permission prompt for
# them; let everything else fall through to the host's normal permission flow.
#
# Read with `pc_publishes` / `pc_is_own_command` rather than matched as globs.
# `*"git commit"*` needs the two words adjacent, so `git -c user.email=… commit`
# and `git -C /repo push` slipped past a gate that looked like it was working.
# Publishing is decided FIRST: `git push && predictable sync` publishes, and
# approving it for its second half would be a way around the gate.
if ! pc_publishes "$cmd"; then
  if pc_is_own_command "$cmd"; then
    pc_emit_allow "Predictable Code: auto-approving the plugin's own \`predictable\` command."
  fi
  exit 0
fi

verdict_file="$(pc_last_verdict_file)"

# `sync --json --claude` auto-initializes the project if needed (product-side), so
# the gate never checks config — it just runs the real sync. If it does not run,
# allow the command and say why, in the CLI's own words from its stderr — never block
# or hang on setup. Every push is said to, not once per session like the turn-end
# notice: each one goes out unchecked. The failure is also recorded, so the agent is
# told at its next prompt (this hook's advisory reaches the user only).
tmp="$verdict_file.tmp.$$"
err="$(pc_stderr_file)"
pc_run_sync "$tmp" "$err"
code=$?
if [ "$code" -ne 0 ]; then
  rm -f "$tmp" 2>/dev/null || true
  text="$(pc_sync_failure_text "$code" "$(pc_sync_failure_reason "$err")")"
  rm -f "$err" 2>/dev/null || true
  pc_record_sync_failure sync-gate "$code" "$text" yes
  pc_log PreToolUse sync-gate "infra-error-$code"
  pc_emit_system_message "Predictable Code: this was not checked — $text Allowing it; only a broken requirement blocks."
  exit 0
fi
rm -f "$err" 2>/dev/null || true
mv "$tmp" "$verdict_file" 2>/dev/null || true
pc_record_sync sync-gate "$verdict_file"
pc_clear_sync_failure

verdict="$(pc_verdict_name "$verdict_file")"
pc_log PreToolUse sync-gate "$verdict"
verbs="$(pc_gated_verbs "$cmd")"

# Only a genuine refutation blocks; everything else is advisory (allow + notice).
case "$verdict" in
  specViolation)
    reason="Predictable Code blocked this command: $(pc_verdict_summary "$verdict"). Fix the refuted requirement(s) and re-run the check until the code is back in sync before the $verbs."
    # Emit the structured deny AND a stderr reason, and exit 2: whichever signal
    # the host honors, the command is blocked.
    pc_emit_deny "$reason"
    printf '%s\n' "$reason" >&2
    exit 2
    ;;
  inSync)
    exit 0
    ;;
  *)
    pc_emit_system_message "Predictable Code: $(pc_verdict_summary "$verdict") — allowing the $verbs (advisory; only a broken requirement blocks)."
    exit 0
    ;;
esac
