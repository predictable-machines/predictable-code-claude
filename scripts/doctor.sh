#!/usr/bin/env sh
# shellcheck shell=sh
#
# Configuration self-check (the plan's L4 "each instance is configured" gate).
# This is a KIT script, not a `predictable` verb — the command surface the plugin
# exposes stays `sync`-only. It asserts the pieces a working install needs and
# prints a report; exit non-zero if any critical check fails.
#
# Usage: scripts/doctor.sh   (from a checked-out plugin repo, or as a hook)

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

plugin_root="${CLAUDE_PLUGIN_ROOT:-$self_dir/..}"
kit_json="$plugin_root/kit.json"
data_dir="$(pc_data_dir)"
runtime_dir="$data_dir/runtime"
manifest="$runtime_dir/MANIFEST.json"

fails=0
ok() { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  fails=$((fails + 1))
}

printf 'Predictable Code — plugin doctor\n'
printf 'data dir: %s\n\n' "$data_dir"

# Wrapper on disk and executable.
wrapper="$plugin_root/bin/predictable"
if [ -x "$wrapper" ]; then ok "wrapper present: $wrapper"; else bad "wrapper missing/not executable: $wrapper"; fi

# Pinned runtime version from kit.json.
expected_version="unknown"
if pc_have_jq && [ -f "$kit_json" ]; then
  expected_version="$(jq -r '.runtimeVersion // "unknown"' "$kit_json" 2>/dev/null || echo unknown)"
  ok "kit.json pins runtime v$expected_version"
else
  warn "kit.json unreadable (jq missing?) — cannot check pinned version"
fi

# Runtime bundle present and version matches.
if [ -f "$manifest" ] && pc_have_jq; then
  have="$(jq -r '.version // "?"' "$manifest" 2>/dev/null || echo '?')"
  if [ "$have" = "$expected_version" ] || [ "$expected_version" = "unknown" ]; then
    ok "runtime bundle present (v$have)"
  else
    bad "runtime bundle version mismatch: bundle=$have pinned=$expected_version"
  fi
  # z3 + toolchain co-located in the bundle.
  if [ -x "$runtime_dir/bin/z3" ]; then ok "z3 resolvable (bundled)"; else warn "z3 not found in bundle bin/ (analysis falls back to system z3)"; fi
  if [ -f "$runtime_dir/lean-toolchain" ]; then ok "Lean toolchain marker present"; else bad "no lean-toolchain in bundle"; fi
  if [ -d "$runtime_dir/workspace/.lake" ]; then ok "prebuilt workspace .lake present"; else bad "no workspace/.lake in bundle (law types won't resolve)"; fi
else
  warn "no runtime bundle installed ($manifest) — fine with a \`predictable\` on PATH; the bundle is fetched at SessionStart only with PREDICTABLE_DIST_TOKEN"
fi

# `predictable` is invokable through the wrapper (dry: --version).
if "$wrapper" --version >/dev/null 2>&1; then
  ok "predictable is invokable through the wrapper"
else
  warn "predictable not invokable yet (no runtime bundle and no predictable on PATH — install it with the command under Settings › Connected machines in the Control Center)"
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf 'doctor: %s critical check(s) failed\n' "$fails"
  exit 1
fi
printf 'doctor: all critical checks passed\n'
exit 0
