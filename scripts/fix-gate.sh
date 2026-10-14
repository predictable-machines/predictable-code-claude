#!/usr/bin/env sh
# shellcheck shell=sh
#
# Fix gate (Stop): an agent fixing a Predictable Code finding may not end its turn until
# `predictable fix-check` says the finding is GONE — no longer reported by a complete sync, and
# the project left with fewer findings than the fix started from.
#
# Active ONLY inside a `predictable fix` session, which names the finding being fixed in the file
# `PREDICTABLE_FIX_TARGET` points at ({fqn, vc, category}); every other session is untouched. The
# driver re-checks after every turn on its own as well, so this gate is the in-session half of a
# loop the driver owns: it saves the turn a premature stop would cost.
#
# It never traps a session:
#   - a check that cannot run (no binary, no answer) lets the turn end — the driver decides;
#   - a second stop with NOTHING changed since the last block lets the turn end — the agent has
#     nothing new to try in this turn, and the driver's own rule decides whether it is stuck.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

stdin_json=$(mktemp 2>/dev/null || echo "/tmp/pc-fix-gate.$$")
cat >"$stdin_json"
cleanup() { rm -f "$stdin_json" 2>/dev/null || true; }

target="${PREDICTABLE_FIX_TARGET:-}"
if [ -z "$target" ] || [ ! -f "$target" ] || ! pc_have_jq; then
  cleanup
  exit 0
fi

fqn="$(jq -r '.fqn // ""' "$target" 2>/dev/null)"
vc="$(jq -r '.vc // ""' "$target" 2>/dev/null)"
category="$(jq -r '.category // ""' "$target" 2>/dev/null)"
if [ -z "$fqn" ] || { [ -z "$vc" ] && [ -z "$category" ]; }; then
  cleanup
  exit 0
fi
if [ -n "$vc" ]; then
  tag_flag=--vc
  tag="$vc"
else
  tag_flag=--category
  tag="$category"
fi

session="$(jq -r '.session_id // "session"' "$stdin_json" 2>/dev/null)"
active="$(jq -r '.stop_hook_active // false' "$stdin_json" 2>/dev/null)"
state_dir="$(pc_data_dir)/fix-gate"
mkdir -p "$state_dir" 2>/dev/null || true
last_digest_file="$state_dir/$session.digest"

bin="$(pc_predictable_bin)"
answer=$(mktemp 2>/dev/null || echo "/tmp/pc-fix-gate-answer.$$")
if [ -n "${PREDICTABLE_FIX_PATH:-}" ]; then
  (cd "$(pc_project_dir)" && "$bin" fix-check --fqn "$fqn" "$tag_flag" "$tag" --json \
    --path "$PREDICTABLE_FIX_PATH") >"$answer" 2>/dev/null
else
  (cd "$(pc_project_dir)" && "$bin" fix-check --fqn "$fqn" "$tag_flag" "$tag" --json) \
    >"$answer" 2>/dev/null
fi
code=$?
verdict="$(jq -r '.verdict // ""' "$answer" 2>/dev/null)"
reason="$(jq -r '.reason // ""' "$answer" 2>/dev/null)"
digest="$(jq -r '.codeDigest // ""' "$answer" 2>/dev/null)"
introduced="$(jq -r '(.introduced // []) | join(", ")' "$answer" 2>/dev/null)"
rm -f "$answer" 2>/dev/null || true

if [ "$code" -ne 0 ] || [ -z "$verdict" ]; then
  pc_log Stop fix-gate "check-unavailable-$code"
  cleanup
  exit 0
fi
if [ "$verdict" = "gone" ]; then
  rm -f "$last_digest_file" 2>/dev/null || true
  pc_log Stop fix-gate gone
  cleanup
  exit 0
fi
# Blocked before and nothing changed since: let the turn end rather than spin on the same tree.
if [ "$active" = "true" ] && [ -n "$digest" ] && [ -f "$last_digest_file" ] &&
  [ "$(cat "$last_digest_file" 2>/dev/null)" = "$digest" ]; then
  pc_log Stop fix-gate "released-no-change-$verdict"
  cleanup
  exit 0
fi
printf '%s' "$digest" >"$last_digest_file" 2>/dev/null || true
pc_log Stop fix-gate "blocked-$verdict"

message="Predictable Code checked the tree and the fix is not done: $verdict — $reason"
if [ -n "$introduced" ]; then
  message="$message
Introduced by your change: $introduced."
fi
message="$message
Keep working on this fix (and on any spec or doc describing behaviour you change), then run \`predictable fix-check --fqn '$fqn' $tag_flag '$tag' --json\` until it reads \`gone\`."
jq -n --arg reason "$message" '{decision: "block", reason: $reason}'
cleanup
exit 0
