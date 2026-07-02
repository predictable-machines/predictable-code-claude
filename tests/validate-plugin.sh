#!/usr/bin/env bash
# L2 plugin validation (no LLM, no bundle): every JSON parses, the manifest
# declares exactly the intended surface (one skill, hooks, NO userConfig, NO MCP
# server), and — privacy-critical — the repo carries NO Predictable source.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
fail=0
ok() { printf '  ok   — %s\n' "$1"; }
bad() {
  printf '  FAIL — %s\n' "$1"
  fail=$((fail + 1))
}
# judge <exit-status> <ok-msg> <fail-msg>
judge() {
  if [ "$1" -eq 0 ]; then ok "$2"; else bad "$3"; fi
}

command -v jq >/dev/null 2>&1 || {
  echo "validate: jq is required"
  exit 1
}

echo "== JSON well-formedness =="
while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1
  judge $? "parses: ${f#"$ROOT"/}" "invalid JSON: ${f#"$ROOT"/}"
done < <(find "$ROOT" -name '*.json' -not -path '*/.git/*')

echo "== plugin.json surface =="
P="$ROOT/.claude-plugin/plugin.json"
jq -e '.name == "predictable-code"' "$P" >/dev/null 2>&1
judge $? "name is predictable-code" "plugin name wrong/missing"
jq -e '.description | length > 0' "$P" >/dev/null 2>&1
judge $? "has description" "description missing"
jq -e 'has("userConfig") | not' "$P" >/dev/null 2>&1
judge $? "no userConfig (zero configuration)" "userConfig present — must be absent"
jq -e 'has("mcpServers") | not' "$P" >/dev/null 2>&1
judge $? "no mcpServers (MCP not shipped)" "mcpServers present — must be absent"

echo "== no bundled MCP config =="
if [ ! -f "$ROOT/.mcp.json" ]; then ok "no .mcp.json"; else bad ".mcp.json present — MCP server must not ship"; fi

echo "== marketplace.json =="
M="$ROOT/.claude-plugin/marketplace.json"
jq -e '.plugins[0].source == "./"' "$M" >/dev/null 2>&1
judge $? "plugin source is ./ (same repo, no git-subdir of source)" "marketplace source wrong"

echo "== hooks.json =="
H="$ROOT/hooks/hooks.json"
for ev in SessionStart UserPromptSubmit PostToolUse PreToolUse Stop; do
  jq -e --arg e "$ev" '.hooks | has($e)' "$H" >/dev/null 2>&1
  judge $? "hook: $ev" "hook missing: $ev"
done
# Every hook is a command hook (portable to Codex, which only runs command hooks).
noncmd=$(jq -r '[.hooks[][].hooks[].type] | map(select(. != "command")) | length' "$H" 2>/dev/null || echo 1)
if [ "$noncmd" = "0" ]; then ok "all hooks are type=command"; else bad "non-command hook types present ($noncmd)"; fi

echo "== single skill =="
skills=$(find "$ROOT/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$skills" = "1" ]; then ok "exactly one skill (sync)"; else bad "expected 1 skill, found $skills"; fi
if [ -f "$ROOT/skills/sync/SKILL.md" ]; then ok "skill is skills/sync"; else bad "skills/sync/SKILL.md missing"; fi

echo "== no bundled agents =="
if [ ! -d "$ROOT/agents" ]; then ok "no agents/ dir"; else bad "agents/ present — none should ship"; fi

echo "== privacy: no Predictable source =="
leak=$(git -C "$ROOT" ls-files 2>/dev/null | grep -E '\.lean$|(^|/)lakefile|(^|/)packages/' || true)
if [ -z "$leak" ]; then
  ok "no .lean / lakefile / packages/ tracked"
else
  bad "source-like files tracked:"
  printf '%s\n' "$leak" | sed 's/^/         /'
fi

echo "== claude plugin validate (if available) =="
if command -v claude >/dev/null 2>&1; then
  claude plugin validate "$ROOT" >/dev/null 2>&1
  judge $? "claude plugin validate passed" "claude plugin validate failed"
else
  printf '  skip — claude CLI not installed\n'
fi

echo
printf 'L2: %s failure(s)\n' "$fail"
[ "$fail" -eq 0 ]
