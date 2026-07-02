#!/usr/bin/env sh
# shellcheck shell=sh
#
# SessionStart hook: ensure the Predictable runtime bundle is present in the
# persistent data dir, downloading it (authenticated, source-free) on first run.
#
# Contract: NEVER hard-fail the host session. A missing token, an offline
# machine, or a dist outage degrades to a `systemMessage` and exit 0; the last
# good runtime (if any) keeps working. The bundle carries the compiled
# `predictable` + `predictable_java_direct` + pinned z3 + relocatable Lean
# toolchain + prebuilt `.lake` oleans — never any Predictable source.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

kit_json="${CLAUDE_PLUGIN_ROOT:-$self_dir/..}/kit.json"
data_dir="$(pc_data_dir)"
runtime_dir="$data_dir/runtime"
manifest="$runtime_dir/MANIFEST.json"
ready="$runtime_dir/.ready"

# Read pinned coordinates from kit.json (defaults keep the script usable if jq
# or the file is missing).
expected_version="0.0.0-dev"
dist_repo="predictable-machines/predictable-code-dist"
asset_pattern="predictable-runtime-{version}-{platform}.tar.zst"
if pc_have_jq && [ -f "$kit_json" ]; then
  expected_version="$(jq -r '.runtimeVersion // "0.0.0-dev"' "$kit_json" 2>/dev/null || echo 0.0.0-dev)"
  dist_repo="$(jq -r '.distRepo // "predictable-machines/predictable-code-dist"' "$kit_json" 2>/dev/null || echo "$dist_repo")"
  asset_pattern="$(jq -r '.assetPattern // "predictable-runtime-{version}-{platform}.tar.zst"' "$kit_json" 2>/dev/null || echo "$asset_pattern")"
fi

# Platform triple: darwin-arm64 | darwin-x64 | linux-x64 | linux-arm64.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x64 ;;
esac
platform="$os-$arch"

# Already have the pinned version? Nothing to do.
if [ -f "$ready" ] && [ -f "$manifest" ] && pc_have_jq; then
  have="$(jq -r '.version // ""' "$manifest" 2>/dev/null || echo "")"
  if [ "$have" = "$expected_version" ]; then
    pc_log SessionStart bootstrap "$(pc_verdict_name "$(pc_last_verdict_file)")"
    exit 0
  fi
fi

# A single-flight lock so concurrent sessions don't race the download.
lock="$data_dir/.bootstrap.lock"
mkdir -p "$data_dir" 2>/dev/null || true
if ! mkdir "$lock" 2>/dev/null; then
  # Another session is already fetching; don't block this one.
  pc_log SessionStart bootstrap locked
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM

fail_advisory() { # message
  pc_emit_system_message "$1"
  pc_log SessionStart bootstrap unavailable
  exit 0
}

token="${PREDICTABLE_DIST_TOKEN:-}"
if [ -z "$token" ]; then
  fail_advisory "Predictable Code: runtime bundle not installed and PREDICTABLE_DIST_TOKEN is unset. Set your distribution token to enable \`predictable sync\`. (No source is ever downloaded; the token only unlocks the compiled runtime.)"
fi

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail_advisory "Predictable Code: \`$tool\` is required to install the runtime bundle but was not found on PATH."
done

version="$expected_version"
asset=$(printf '%s' "$asset_pattern" | sed -e "s/{version}/$version/g" -e "s/{platform}/$platform/g")

tmp=$(mktemp -d 2>/dev/null || echo "$data_dir/.tmp.$$")
mkdir -p "$tmp" 2>/dev/null || true

# Resolve the release-asset download URL from the dist repo via the GitHub API,
# authenticated with the distribution token (scoped to artifacts only). A 404 /
# auth failure here can never expose source — the token has no source access.
api="https://api.github.com/repos/$dist_repo/releases/tags/v$version"
asset_url=$(curl -fsSL -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.github+json" "$api" 2>/dev/null |
  (pc_have_jq && jq -r --arg a "$asset" '.assets[]? | select(.name == $a) | .url' 2>/dev/null || true) |
  head -1)

if [ -z "$asset_url" ]; then
  rm -rf "$tmp" 2>/dev/null || true
  fail_advisory "Predictable Code: could not resolve runtime asset \`$asset\` in \`$dist_repo\` (v$version). Keeping any previously installed runtime."
fi

# Assets endpoint needs the octet-stream Accept header to get bytes, not JSON.
if ! curl -fsSL -H "Authorization: Bearer $token" \
  -H "Accept: application/octet-stream" -o "$tmp/$asset" "$asset_url" 2>/dev/null; then
  rm -rf "$tmp" 2>/dev/null || true
  fail_advisory "Predictable Code: runtime download failed (network or auth). Keeping any previously installed runtime."
fi

# Verify the checksum against the per-asset `<asset>.sha256` sidecar when present
# (the format `make bundle` emits — one bare hash, no filename). Per-asset rather
# than a shared SHA256SUMS so per-platform release uploads never race.
sha_name="$asset.sha256"
sha_url=$(curl -fsSL -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.github+json" "$api" 2>/dev/null |
  (pc_have_jq && jq -r --arg s "$sha_name" '.assets[]? | select(.name == $s) | .url' 2>/dev/null || true) |
  head -1)
if [ -n "$sha_url" ]; then
  if curl -fsSL -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" \
    -o "$tmp/$sha_name" "$sha_url" 2>/dev/null; then
    expected=$(awk '{print $1}' "$tmp/$sha_name" | head -1)
    actual=$(sha256sum "$tmp/$asset" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$tmp/$asset" | awk '{print $1}')
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
      rm -rf "$tmp" 2>/dev/null || true
      fail_advisory "Predictable Code: runtime checksum mismatch for $asset — refusing to install. Keeping any previously installed runtime."
    fi
  fi
fi

# Extract atomically: unpack into a staging dir, then swap it into place so a
# crash mid-extract never leaves a half-written runtime.
staging="$data_dir/.runtime.new.$$"
rm -rf "$staging" 2>/dev/null || true
mkdir -p "$staging" 2>/dev/null || true
if ! tar --use-compress-program=zstd -xf "$tmp/$asset" -C "$staging" 2>/dev/null; then
  # zstd may not be wired into tar; fall back to a piped decompress.
  if ! (zstd -dc "$tmp/$asset" 2>/dev/null | tar -xf - -C "$staging" 2>/dev/null); then
    rm -rf "$tmp" "$staging" 2>/dev/null || true
    fail_advisory "Predictable Code: could not extract the runtime bundle (need \`zstd\`). Keeping any previously installed runtime."
  fi
fi

# The tarball's top-level dir is `predictable-runtime-<ver>-<platform>/`; flatten
# it to `$runtime_dir`.
inner=$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$inner" ] || inner="$staging"
rm -rf "$runtime_dir" 2>/dev/null || true
mv "$inner" "$runtime_dir" 2>/dev/null || cp -R "$inner" "$runtime_dir"
: >"$ready"

rm -rf "$tmp" "$staging" 2>/dev/null || true
pc_emit_system_message "Predictable Code: installed runtime v$version for $platform."
pc_log SessionStart bootstrap installed
exit 0
