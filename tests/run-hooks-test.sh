#!/usr/bin/env bash
# L1 hook-contract tests (the plan's fast, deterministic, no-LLM, no-bundle
# gate). Pipes captured stdin fixtures into each hook script and asserts the
# stdout JSON, exit code, side effects (hook-events.log, last-verdict), and — for
# bootstrap — that a failure path never leaks source.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)
STUB="$ROOT/tests/stub-predictable.sh"
chmod +x "$ROOT"/scripts/*.sh "$ROOT"/bin/predictable "$STUB" 2>/dev/null || true

pass=0
fail=0
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT

fresh_data() {
  # A `VAR=x run_hook …` prefix on a FUNCTION call persists in the shell after
  # it returns, so a stub knob set by one test silently governed every later one
  # — a `STUB_FAIL=1` four tests up turned a deny case into an infra-error
  # allow, and the test read as a broken gate rather than a leaked variable.
  unset STUB_FAIL STUB_VERDICT STUB_SESSION_OUT STUB_STDERR STUB_EXIT PREDICTABLE_SESSION_ID \
    STUB_FIXCHECK PREDICTABLE_FIX_TARGET PREDICTABLE_FIX_PATH
  DATA=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$DATA"
  PROJ=$(mktemp -d)
  export CLAUDE_PROJECT_DIR="$PROJ"
  # Default to a CONFIGURED project so sync-running tests exercise the sync path.
  # A test that wants the unconfigured path calls unconfigure.
  mkdir -p "$PROJ/.predictable-code"
  printf '{}' >"$PROJ/.predictable-code/project.json"
}

unconfigure() { rm -f "$CLAUDE_PROJECT_DIR/.predictable-code/project.json"; }

# Run a hook script with a fixture on stdin. Sets OUT/CODE.
run_hook() { # script fixture
  OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PREDICTABLE_BIN="$STUB" \
    "$ROOT/scripts/$1" <"$ROOT/fixtures/$2" 2>"$ERRFILE")
  CODE=$?
}

check() { # description condition-result(0=ok)
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1))
    printf '  ok   — %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL — %s\n' "$1"
    [ -n "${3:-}" ] && printf '         %s\n' "$3"
  fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/bin/predictable; then
    check "shellcheck clean" 0
  else
    check "shellcheck clean" 1 "shellcheck reported issues (see above)"
  fi
else
  printf '  skip — shellcheck not installed\n'
fi

echo "== sync-gate =="

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
contains "$OUT" '"permissionDecision": "deny"'
check "git push + specViolation -> deny JSON" $?
rc=1
[ "$CODE" -eq 2 ] && rc=0
check "git push + specViolation -> exit 2" "$rc" "got exit $CODE"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'deny' && rc=0
check "git push + verificationError -> advisory allow (no block)" "$rc" "exit $CODE out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny'
check "git push + inSync -> allow (exit 0, no deny)" $? "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-bash-noop.json
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "non-git Bash -> passthrough (exit 0, no output)" "$rc" "exit $CODE out=$OUT"

fresh_data
STUB_FAIL=1 run_hook sync-gate.sh pre-tool-use-git-push.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'deny'
check "git push + sync infra error -> allow + systemMessage (never trap)" $? "exit $CODE out=$OUT"

# git's global options sit between the program and its subcommand, so a glob
# needing the two words adjacent never matched these — the gate ran, looked
# healthy, and let them through. Caught by checking HEAD, not by the gate.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-commit-options.json
rc=1
[ "$CODE" -eq 2 ] && contains "$OUT" '"permissionDecision": "deny"' && rc=0
check "git -c … commit + specViolation -> deny (options do not hide the subcommand)" "$rc" "exit $CODE out=$OUT"

# Publishing is decided before auto-approval, or the second half of the line
# would be a way around the gate.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-push-ridealong.json
rc=1
[ "$CODE" -eq 2 ] && contains "$OUT" '"permissionDecision": "deny"' && rc=0
check "git push && predictable sync -> deny (no ride-along approval)" "$rc" "exit $CODE out=$OUT"

# The gate blocks only on specViolation, so the session summary may count only those.
# It counted every non-inSync gate event: three allowed passes (noCode, mechanical,
# mechanical) read "gate blocked 3 push(es)" while nothing had been blocked (#2505).
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical.json" \
  run_hook sync-gate.sh pre-tool-use-git-commit-options.json
run_hook status-context.sh user-prompt-submit.json
rc=1
! contains "$OUT" 'blocked' && rc=0
check "allowed gate passes are not counted as blocked" "$rc" "out=$OUT"

STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
run_hook status-context.sh user-prompt-submit.json
rc=1
contains "$OUT" 'the gate blocked 1 commit or push' && rc=0
check "a denied push is counted as blocked, and only it" "$rc" "out=$OUT"

# The notice names the command it gated: a commit is not a push.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-commit-options.json
rc=1
contains "$OUT" 'allowing the commit (advisory' && ! contains "$OUT" 'push' && rc=0
check "git commit + verificationError -> the notice says commit, not push" "$rc" "out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
contains "$OUT" 'allowing the push (advisory' && rc=0
check "git push + verificationError -> the notice says push" "$rc" "out=$OUT"

# Claude Code renders every systemMessage as an alarm (a red block on mobile, #2507), so a
# pass the user need not act on says nothing; the status line shows the verdict.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "git push + mechanical -> allowed in silence (no alarm-styled systemMessage)" "$rc" "out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
contains "$OUT" 'systemMessage' && contains "$OUT" 'issue' && rc=0
check "Stop + specViolation -> the summary IS a systemMessage (the user must act)" "$rc" "out=$OUT"

# A read-only git command that merely contains the word must not run a check.
fresh_data
run_hook sync-gate.sh pre-tool-use-git-log.json
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "git log --grep=commit -> passthrough (no check)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-predictable-sync.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable sync -> auto-allow (no permission prompt)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-predictable-init.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable init -> auto-allow (setup runs without prompt)" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-report-link.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "the report's Control Center link -> auto-allow (opens without prompt)" "$rc" "exit $CODE out=$OUT"

# The link script carries only ITSELF: named inside another command it approves nothing.
fresh_data
run_hook sync-gate.sh pre-tool-use-report-link-smuggled.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" '"permissionDecision": "allow"' && rc=0
check "a command merely naming the link script -> NOT auto-allowed" "$rc" "exit $CODE out=$OUT"

# `predictable serve` is a deleted verb: nothing auto-approves it any more.
fresh_data
run_hook sync-gate.sh pre-tool-use-serve.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" '"permissionDecision": "allow"' && rc=0
check "predictable serve (deleted) -> NOT auto-allowed" "$rc" "exit $CODE out=$OUT"

fresh_data
run_hook sync-gate.sh pre-tool-use-agent-verify.json
rc=1
contains "$OUT" '"permissionDecision": "allow"' && [ "$CODE" -eq 0 ] && rc=0
check "predictable specs requirements agent-verify -> auto-allow (records reviewed fix)" "$rc" "exit $CODE out=$OUT"

echo "== progress formatter (#1237 NDJSON -> friendly lines) =="

if command -v jq >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # the backticks are the CLI's literal text
  PROG_IN=$(printf '%s\n' \
    '{"v":1,"event":"phase","phase":"translation","state":"start","files":42}' \
    'a schema-drift warning, not json' \
    '{"v":1,"event":"phase","phase":"analysis","state":"done","functions":30,"findings":7}' \
    '{"v":1,"event":"phase","phase":"inference","state":"done"}' \
    '{"v":1,"event":"phase","phase":"requirements","state":"done","checked":12,"verified":10,"violated":2}' \
    '42' \
    'Predictable Code: /r/.predictable-code is a `.predictable-code/` from before the database; run `predictable migrate`, then run this again.')
  PROG_OUT=$(printf '%s\n' "$PROG_IN" | jq --unbuffered -jR -f "$ROOT/scripts/progress.jq" 2>"$ERRFILE")
  PROG_CODE=$?
  rc=1
  [ "$PROG_CODE" -eq 0 ] \
    && contains "$PROG_OUT" 'Reading your code' \
    && contains "$PROG_OUT" 'Analyzed 30 function(s) — 7 potential issue(s)' \
    && contains "$PROG_OUT" 'Specification inferred' \
    && contains "$PROG_OUT" '10 of 12 requirement(s) verified · 2 refuted' \
    && ! contains "$PROG_OUT" 'not json' \
    && rc=0
  check "progress.jq maps phase events to domain lines, drops non-JSON" "$rc" "exit=$PROG_CODE out=$PROG_OUT"
  # The CLI's refusal is the one plain line that must get through: it is the only thing
  # a run that wrote no envelope says about why.
  rc=1
  contains "$PROG_OUT" '⚠️ Predictable Code: /r/.predictable-code is a' \
    && contains "$PROG_OUT" 'predictable migrate' && rc=0
  check "progress.jq lets the CLI's 'Predictable Code: …' refusal through" "$rc" "out=$PROG_OUT"
  # SKILL.md carries this filter inline (the skill's shell cannot path to the file), and
  # the two had already drifted apart: run the copy the agent actually executes.
  SKILL_FILTER=$(awk '
    /\| jq --unbuffered -jR '\''$/ { on = 1; next }
    on && /'\''$/ { sub(/'\''$/, ""); print; exit }
    on { print }
  ' "$ROOT/skills/sync/SKILL.md")
  SKILL_OUT=$(printf '%s\n' "$PROG_IN" | jq --unbuffered -jR "$SKILL_FILTER" 2>"$ERRFILE")
  rc=1
  [ -n "$SKILL_FILTER" ] && [ "$SKILL_OUT" = "$PROG_OUT" ] && rc=0
  check "SKILL.md's inline progress filter does exactly what progress.jq does" "$rc" \
    "skill=$SKILL_OUT"
else
  check "progress.jq (skipped — jq not installed)" 0 ""
fi

echo "== fix-gate =="

# A fix session names its finding in the file PREDICTABLE_FIX_TARGET points at.
fix_target() {
  PREDICTABLE_FIX_TARGET="$DATA/target.json"
  export PREDICTABLE_FIX_TARGET
  printf '{"fqn":"Code.cards.totalUnits","vc":"il1.null-dereference","category":null}' \
    >"$PREDICTABLE_FIX_TARGET"
}
reported() {
  STUB_FIXCHECK="$DATA/answer.json"
  export STUB_FIXCHECK
  printf '{"verdict":"%s","reason":"%s","codeDigest":"%s","introduced":[%s]}' \
    "$1" "$2" "$3" "${4:-}" >"$STUB_FIXCHECK"
}

fresh_data
run_hook fix-gate.sh stop.json
rc=1
[ -z "$OUT" ] && [ "$CODE" -eq 0 ] && rc=0
check "fix-gate outside a fix session -> silent, never blocks" "$rc" "got exit $CODE: $OUT"

fresh_data
fix_target
reported reported "a complete sync still reports it" d1
run_hook fix-gate.sh stop.json
contains "$OUT" '"decision": "block"' && contains "$OUT" 'still reports it'
check "fix-gate reported -> block, quoting the check" $?
contains "$OUT" "fix-check --fqn 'Code.cards.totalUnits' --vc 'il1.null-dereference'"
check "fix-gate tells the agent the exact check to run" $?

fresh_data
fix_target
reported regressed "it is gone, but the change introduced 1 new finding" d2 '"Code.cards.lastUnits|il1.x"'
run_hook fix-gate.sh stop.json
contains "$OUT" '"decision": "block"' && contains "$OUT" 'Code.cards.lastUnits|il1.x'
check "fix-gate regressed -> block, naming what the change introduced" $?

fresh_data
fix_target
reported gone "no longer reported" d3
run_hook fix-gate.sh stop.json
rc=1
[ -z "$OUT" ] && [ "$CODE" -eq 0 ] && rc=0
check "fix-gate gone -> the turn may end" "$rc" "got: $OUT"

fresh_data
fix_target
reported reported "still reported" d4
run_hook fix-gate.sh stop.json
run_hook fix-gate.sh stop-hook-active.json
rc=1
[ -z "$OUT" ] && rc=0
check "fix-gate blocked before and nothing changed -> released (no spin)" "$rc" "got: $OUT"
reported reported "still reported" d5
run_hook fix-gate.sh stop-hook-active.json
contains "$OUT" '"decision": "block"'
check "fix-gate blocked before but the code changed -> blocks again" $?

fresh_data
fix_target
STUB_FAIL=1 run_hook fix-gate.sh stop.json
rc=1
[ -z "$OUT" ] && [ "$CODE" -eq 0 ] && rc=0
check "fix-gate check cannot run -> never traps the session" "$rc" "got exit $CODE: $OUT"

echo "== control-center-url (the /predictable-code:report link) =="

# The link names the project EXACTLY as the Control Center's `cloudProjectIdOf` does:
# `gh-<owner>.<name>`, lowercased, anything outside a part's alphabet written `~hh`. The old
# rule folded non-alphanumerics to `-`, so Bridge's link opened "gh-predictable-machines-javi-bridge
# isn't registered here" (#2527). The expected ids are the Control Center's own output; the last
# two would be ONE project under the old rule.
url_for() { # origin
  _home=$(mktemp -d)
  mkdir -p "$_home/.predictable-code"
  printf '{"url":"http://localhost:5473/"}' >"$_home/.predictable-code/cloud-session.json"
  fresh_data
  git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null
  git -C "$CLAUDE_PROJECT_DIR" remote add origin "$1"
  HOME="$_home" sh "$ROOT/scripts/control-center-url.sh"
  rm -rf "$_home"
}
for pair in \
  "git@github.com:Predictable-Machines-Javi/bridge.git|gh-predictable-machines-javi.bridge" \
  "https://github.com/acme/foo.bar.git|gh-acme.foo.bar" \
  "https://github.com/Acme/Naïve.Repo|gh-acme.na~c3~afve.repo" \
  "https://github.com/acme/foo-bar|gh-acme.foo-bar" \
  "https://github.com/acme-foo/bar|gh-acme-foo.bar"; do
  origin=${pair%%|*}
  want=${pair#*|}
  got=$(url_for "$origin")
  rc=1
  [ "$got" = "http://localhost:5473/?project=$want" ] && rc=0
  check "report link for $origin names project $want" "$rc" "got: $got"
done

echo "== sync-run =="

# A non-Stop event exercises emit_advisory's additionalContext fallback branch.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && contains "$OUT" 'Proven in sync'
check "sync-run clean -> exit 0, verdict persisted, summary emitted" $? "exit $CODE out=$OUT"

fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-specViolation.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'issue'
check "sync-run with open issues -> summary in additionalContext (fallback)" $? "exit $CODE out=$OUT"

echo "== metric: issues found -> fixed (branding) =="

fresh_data
# Iteration 1: verificationError = 3 issues (1 real + 2 refuted).
STUB_VERDICT="$ROOT/fixtures/verdict-verificationError.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
contains "$OUT" 'issue' && ! contains "$OUT" 'Proven'
check "iter1 (verificationError) -> reports open issues" $? "out=$OUT"

# Iteration 2 at Stop: inSync = 0 issues. Routine news is not a systemMessage, which Claude
# Code renders as an alarm (#2507): the status line shows it, and the next prompt's context
# carries the closing summary below.
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'systemMessage' && rc=0
check "iter2 (inSync) at Stop -> no alarm-styled systemMessage" "$rc" "out=$OUT"

run_hook status-context.sh user-prompt-submit.json
contains "$OUT" 'Proven in sync' && contains "$OUT" 'fixed all 3'
check "status-context surfaces the same session summary" $? "out=$OUT"

hist_lines=$(wc -l <"$DATA/session-history.jsonl" 2>/dev/null | tr -d ' ')
rc=1
[ "$hist_lines" = "2" ] && rc=0
check "session-history recorded 2 syncs" "$rc" "history=$(cat "$DATA/session-history.jsonl" 2>/dev/null)"

# A fresh session (SessionStart:startup) resets the tally for the next run.
run_hook status-context.sh session-start.json
contains "$OUT" 'no check' && [ ! -f "$DATA/session-history.jsonl" ]
check "SessionStart:startup resets the session tally" $? "out=$OUT"

echo "== session-sync (SessionStart fires 'sync --json --claude' detached) =="

# startup + git repo -> fires the first sync (--claude auto-inits product-side),
# persists verdict. No config check in the hook.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null || true
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start.json
rc=1
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart(startup)+git -> fires sync, persists verdict" "$rc" "exit $CODE"
rc=1
contains "$OUT" 'additionalContext' && ! contains "$OUT" 'systemMessage' && rc=0
check "SessionStart(startup) -> tells the agent, no alarm-styled systemMessage" "$rc" "out=$OUT"

# resume source -> no-op (state already exists; don't re-sync).
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null || true
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start-resume.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart(resume) -> no-op (no sync)" "$rc" "verdict=$([ -f "$DATA/last-verdict.json" ] && echo yes || echo no)"

# not a git repo -> never scaffold.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart non-git dir -> no-op (never scaffold)" "$rc" "verdict=$([ -f "$DATA/last-verdict.json" ] && echo yes || echo no)"

echo "== metric counts analysis findings =="

# pc_issue_count, with no `findingsTotal` in the verdict, counts the analysis results'
# findings — reachable-now AND potential — over the verdict counters (inSync would
# otherwise count 0).
fresh_data
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/verification"
printf '{"findingsAffecting": 7, "findingsPotential": 3}' \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/verification/.analysis-results.json"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "10" ] && rc=0
check "metric counts affecting + potential findings (10), not the inSync verdict (0)" "$rc" "issues=$iss"

# And the sync's own `findingsTotal` wins when the verdict carries one: it is the number the
# Control Center shows for the same analysis. Measured: "5 issue(s) open" from
# `findingsAffecting` alone, over an analysis listing 63.
fresh_data
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "63" ] && rc=0
check "metric counts the sync's findingsTotal (63)" "$rc" "issues=$iss"

# The ENVELOPE `sync --json` writes today carries the verdict under `.result`, with `findings`
# as its first key: read as the bare shape it found no count and summed another denominator
# (measured: 911 beside a status line saying 48).
fresh_data
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/verification"
printf '{"findingsAffecting": 600, "findingsPotential": 311}' \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/verification/.analysis-results.json"
STUB_VERDICT="$ROOT/fixtures/verdict-mechanical-envelope.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
iss=$(jq -r '.issues' "$DATA/session-history.jsonl" 2>/dev/null | tail -1)
rc=1
[ "$iss" = "48" ] && rc=0
check "metric reads findingsTotal out of the envelope (48), not the analysis sum (911)" "$rc" "issues=$iss"

echo "== envelope verdict parsing (#1236) =="

# pc_verdict_name reads the verdict from the new envelope (.result) and the older
# bare shape ({<verdict>:…}) alike.
fresh_data
printf '{"schemaVersion":1,"result":{"mechanical":{}},"findings":[]}' >"$DATA/env.json"
printf '{"inSync":{}}' >"$DATA/bare.json"
v_env=$( . "$ROOT/scripts/lib.sh"; pc_verdict_name "$DATA/env.json" )
v_bare=$( . "$ROOT/scripts/lib.sh"; pc_verdict_name "$DATA/bare.json" )
rc=1
[ "$v_env" = "mechanical" ] && [ "$v_bare" = "inSync" ] && rc=0
check "pc_verdict_name handles envelope (.result) + bare shapes" "$rc" "env=$v_env bare=$v_bare"

echo "== the database layout =="

# In a git checkout `.predictable-code/` is the database (a worktree, its `.git` a FILE), and the
# runtime's state for the checked-out branch is that branch's entry — `feature/x` included, whose
# name holds a slash. Elsewhere it is `.predictable-code/` itself.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q -b feature/x
printf 'gitdir: /elsewhere\n' >"$CLAUDE_PROJECT_DIR/.predictable-code/.git"
state=$( . "$ROOT/scripts/lib.sh"; pc_state_dir )
rc=1
[ "$state" = "$CLAUDE_PROJECT_DIR/.predictable-code/feature/x/.predictable-code" ] && rc=0
check "pc_state_dir is the checked-out branch's entry in a database" "$rc" "state=$state"
mkdir -p "$state"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x"}' "$$" >"$state/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "a live lock in the branch's entry is a running sync" "$rc" "running=$running"
fresh_data
state=$( . "$ROOT/scripts/lib.sh"; pc_state_dir )
rc=1
[ "$state" = "$CLAUDE_PROJECT_DIR/.predictable-code" ] && rc=0
check "pc_state_dir is .predictable-code itself outside a database" "$rc" "state=$state"

echo "== concurrency guard =="

fresh_data
# Simulate an in-flight `predictable sync` (argv0 spoofed via exec -a) so the
# guard must skip rather than start a second, colliding sync. A running sync
# is detected via the runtime's project sync lock (live pid), so simulate one:
# this test shell's own pid is alive for the duration.
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x"}' "$$" \
  > "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rm -f "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/session-history.jsonl" ] \
  && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "sync already running -> skip (no second sync, logs skipped-running)" "$rc" \
  "exit $CODE hist=$([ -f "$DATA/session-history.jsonl" ] && echo yes || echo no)"

# In a database checkout the CLI takes its lock in the checked-out branch's entry, and
# the HOOK must look there: a SessionStart sync and a Stop sync 3 s apart both ran in a
# release test.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q -b main
printf 'gitdir: /elsewhere\n' >"$CLAUDE_PROJECT_DIR/.predictable-code/.git"
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code/main/.predictable-code"
printf '{"pid": %s, "runId": "l1-test", "inputsDigest": "x", "stage": "database"}' "$$" \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/main/.predictable-code/.sync.lock"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/session-history.jsonl" ] \
  && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "a live lock in the branch's entry -> the turn-end hook starts no second sync" "$rc" \
  "exit $CODE hist=$([ -f "$DATA/session-history.jsonl" ] && echo yes || echo no)"

# The CLI creates the lock and then writes its record into it, so a hook can meet it empty
# or half-written: that is a sync starting, and starting another beside it is the race.
fresh_data
: >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "an empty lock file (being written) counts as running" "$rc" "running=$running"
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ ! -f "$DATA/session-history.jsonl" ] && grep -q 'skipped-running' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "an empty lock file -> the turn-end hook starts no second sync" "$rc"

printf '{"pid": 12' >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "yes" ] && rc=0
check "a half-written lock record counts as running" "$rc" "running=$running"

# ...but only briefly: an unreadable lock nobody has touched for minutes was abandoned,
# and reading it as running for ever would stop every hook from syncing again.
: >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
touch -t 200001010000 "$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "no" ] && rc=0
check "an empty lock file left for long is not a running sync" "$rc" "running=$running"

# A lock naming a pid that is gone is stale (the CLI clears it on its next acquire).
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf '{"pid": %s, "runId": "gone", "inputsDigest": "x"}' "$dead_pid" \
  >"$CLAUDE_PROJECT_DIR/.predictable-code/.sync.lock"
running=$( . "$ROOT/scripts/lib.sh"; pc_sync_running && echo yes || echo no )
rc=1
[ "$running" = "no" ] && rc=0
check "a lock naming a dead pid is not a running sync" "$rc" "running=$running pid=$dead_pid"

echo "== status-context =="

fresh_data
cp "$ROOT/fixtures/verdict-specViolation.json" "$DATA/last-verdict.json"
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'additionalContext' && contains "$OUT" 'SPEC VIOLATION'
check "UserPromptSubmit with stored verdict -> additionalContext" $? "exit $CODE out=$OUT"

fresh_data
run_hook status-context.sh user-prompt-submit.json
[ "$CODE" -eq 0 ] && contains "$OUT" 'no check'
check "UserPromptSubmit with no verdict -> 'no check yet' context" $? "exit $CODE out=$OUT"

echo "== session =="
# Every sync a hook starts names the session it runs for, so the Control Center
# keeps one run per session rather than a row per turn-end check.
fresh_data
SESSION_OUT=$(mktemp)
STUB_SESSION_OUT="$SESSION_OUT" STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  PREDICTABLE_SYNC_FOREGROUND=1 run_hook sync-run.sh stop.json
GOT_SESSION=$(cat "$SESSION_OUT")
contains "<$GOT_SESSION>" "<fixture-session>"
check "a turn-end sync carries the hook's session_id as PREDICTABLE_SESSION_ID" $? "got=$GOT_SESSION"
rm -f "$SESSION_OUT"
unset STUB_SESSION_OUT

echo "== a sync that does not run is said, never dropped =="

# The CLI refuses a checkout whose `.predictable-code/` is from before the database: exit 1,
# nothing on stdout, ONE line on stderr naming `predictable migrate`. Every hook threw stderr
# away and read the exit as "runtime unavailable", so the refusal reached nobody.
MIGRATE="$ROOT/fixtures/sync-stderr-migrate.txt"
# The backticks are the CLI's literal text, not a command substitution.
# shellcheck disable=SC2016
SENTENCE='from before the database; run `predictable migrate`'
json_ok() { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }
message_of() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>/dev/null; }
context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# The reason is the last stderr line that is not a progress event, without the CLI's prefix.
reason=$( . "$ROOT/scripts/lib.sh"; pc_sync_failure_reason "$MIGRATE" )
rc=1
# shellcheck disable=SC2016  # literal backticks, as the CLI writes them
case "$reason" in
  '/tmp/l1-project/.predictable-code is a `.predictable-code/` from before the database;'*'then run this again.') rc=0 ;;
esac
check "the reason is the refusal sentence, not the NDJSON line after it" "$rc" "reason=$reason"

# Turn end (detached in a session; foreground here): the user is told, in the CLI's words.
fresh_data
STUB_STDERR="$MIGRATE" STUB_EXIT=1 PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
msg=$(message_of "$OUT")
rc=1
[ "$CODE" -eq 0 ] && json_ok "$OUT" && contains "$msg" "$SENTENCE" \
  && contains "$msg" 'the check did not run' && ! contains "$OUT" '"event"' && rc=0
check "Stop + a refused sync -> the migrate sentence reaches the systemMessage" "$rc" "exit $CODE out=$OUT"
rc=1
[ ! -f "$DATA/last-verdict.json" ] && [ ! -f "$DATA/session-history.jsonl" ] \
  && grep -q 'failed-1' "$DATA/hook-events.log" 2>/dev/null && rc=0
check "a refused sync writes no verdict and no history, and is logged failed-1" "$rc"

# Said to the user ONCE per session: the same refusal at every turn end is one thing to say.
STUB_STDERR="$MIGRATE" STUB_EXIT=1 PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" "$SENTENCE" && rc=0
check "the same refusal at the next turn end is not said to the user again" "$rc" "out=$OUT"

# ...but the AGENT is told at every prompt while it stands, with what to do about it.
run_hook status-context.sh user-prompt-submit.json
ctx=$(context_of "$OUT")
rc=1
json_ok "$OUT" && contains "$ctx" "$SENTENCE" && contains "$ctx" 'predictable migrate --force' \
  && [ -z "$(message_of "$OUT")" ] && rc=0
check "next prompt -> the agent's context carries the refusal and the migrate step (user not re-told)" "$rc" "out=$OUT"

# A sync that runs clears it.
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
run_hook status-context.sh user-prompt-submit.json
rc=1
! contains "$OUT" 'did not run' && rc=0
check "a sync that runs clears the standing refusal" "$rc" "out=$OUT"

# The detached SessionStart sync: its hook has returned by the time it fails, so the outcome
# is recorded and the next status-context says it — to the user once, to the agent each turn.
fresh_data
git -C "$CLAUDE_PROJECT_DIR" init -q 2>/dev/null || true
STUB_STDERR="$MIGRATE" STUB_EXIT=1 PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook session-sync.sh session-start.json
rc=1
[ "$CODE" -eq 0 ] && [ ! -f "$DATA/last-verdict.json" ] && rc=0
check "SessionStart + a refused sync -> exit 0, no verdict" "$rc" "exit $CODE"
run_hook status-context.sh user-prompt-submit.json
rc=1
contains "$(message_of "$OUT")" "$SENTENCE" && contains "$(context_of "$OUT")" "$SENTENCE" && rc=0
check "the SessionStart refusal reaches the next prompt: user AND agent" "$rc" "out=$OUT"
run_hook status-context.sh user-prompt-submit.json
rc=1
[ -z "$(message_of "$OUT")" ] && contains "$(context_of "$OUT")" "$SENTENCE" && rc=0
check "the prompt after: the agent still told, the user not again" "$rc" "out=$OUT"
# A new session tells the user again: the reader may not be the one who saw it.
other_session=$(mktemp)
jq '.session_id = "another-session"' "$ROOT/fixtures/user-prompt-submit.json" >"$other_session"
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PREDICTABLE_BIN="$STUB" \
  "$ROOT/scripts/status-context.sh" <"$other_session" 2>"$ERRFILE")
rm -f "$other_session"
contains "$(message_of "$OUT")" "$SENTENCE"
check "a new session tells the user once more" $? "out=$OUT"

# The gate: a refusal never blocks (only specViolation does), and it is said.
fresh_data
STUB_STDERR="$MIGRATE" STUB_EXIT=1 run_hook sync-gate.sh pre-tool-use-git-push.json
msg=$(message_of "$OUT")
rc=1
[ "$CODE" -eq 0 ] && json_ok "$OUT" && ! contains "$OUT" 'deny' \
  && contains "$msg" "$SENTENCE" && contains "$msg" 'not checked' && rc=0
check "git push + a refused sync -> allowed, and the systemMessage quotes the refusal" "$rc" "exit $CODE out=$OUT"
run_hook status-context.sh user-prompt-submit.json
rc=1
contains "$(context_of "$OUT")" "$SENTENCE" && [ -z "$(message_of "$OUT")" ] && rc=0
check "after the gate said it, the agent is told at the next prompt (the user is not re-told)" "$rc" "out=$OUT"

# Progress events alone are no reason: a JSON line is never quoted as one.
fresh_data
STUB_STDERR="$ROOT/fixtures/sync-stderr-progress-only.txt" STUB_EXIT=1 \
  run_hook sync-gate.sh pre-tool-use-git-push.json
msg=$(message_of "$OUT")
rc=1
[ "$CODE" -eq 0 ] && contains "$msg" 'exited 1 without saying why' && ! contains "$msg" 'phase' && rc=0
check "stderr with only NDJSON progress -> no JSON quoted as the reason" "$rc" "out=$OUT"

# No runtime at all (the wrapper's 127) keeps its own wording and is bootstrap's to advise:
# not recorded, so the agent is not told about it at every prompt.
fresh_data
STUB_EXIT=127 run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && contains "$(message_of "$OUT")" 'runtime is not available' && rc=0
check "git push + no runtime (127) -> allowed, says the runtime is not available" "$rc" "out=$OUT"
run_hook status-context.sh user-prompt-submit.json
rc=1
! contains "$OUT" 'did not run' && rc=0
check "no runtime (127) is not recorded as a standing failure" "$rc" "out=$OUT"

# One repository's refusal is not another's: the plugin's data dir is shared by all of them.
fresh_data
STUB_STDERR="$MIGRATE" STUB_EXIT=1 PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh stop.json
CLAUDE_PROJECT_DIR=$(mktemp -d)
mkdir -p "$CLAUDE_PROJECT_DIR/.predictable-code"
printf '{}' >"$CLAUDE_PROJECT_DIR/.predictable-code/project.json"
run_hook status-context.sh user-prompt-submit.json
rc=1
! contains "$OUT" 'did not run' && rc=0
check "a refusal in one repository is not reported in another" "$rc" "out=$OUT"
export CLAUDE_PROJECT_DIR="$PROJ"

echo "== bootstrap =="

# Dev fallback: a `predictable` on PATH + no token -> stay quiet (no nag).
fresh_data
fakebin=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' >"$fakebin/predictable"
chmod +x "$fakebin/predictable"
unset PREDICTABLE_DIST_TOKEN
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$fakebin:$PATH" "$ROOT/scripts/bootstrap.sh" <"$ROOT/fixtures/session-start.json" 2>"$ERRFILE")
CODE=$?
rc=1
[ "$CODE" -eq 0 ] && [ -z "$OUT" ] && rc=0
check "predictable on PATH, no token -> quiet (no nag)" "$rc" "exit $CODE out=$OUT"

# Nothing usable: no token, no predictable, no bundle -> clean advisory, no leak.
fresh_data
unset PREDICTABLE_DIST_TOKEN
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/scripts/bootstrap.sh" <"$ROOT/fixtures/session-start.json" 2>"$ERRFILE")
CODE=$?
rc=1
[ "$CODE" -eq 0 ] && contains "$OUT" 'systemMessage' && ! contains "$OUT" 'packages/Predictable' && ! contains "$OUT" '.lean' && rc=0
check "no token/predictable/bundle -> advisory, exit 0, no leak" "$rc" "exit $CODE out=$OUT"

echo "== no config gate (scripts just run 'sync --json --claude'; product auto-inits) =="

# The plugin never checks config — it runs `sync --json --claude` and the PRODUCT
# auto-initializes if needed. So even unconfigured, the hook runs sync + records a
# verdict (the stub just prints one; it doesn't init — that's the product's job).
fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" PREDICTABLE_SYNC_FOREGROUND=1 \
  run_hook sync-run.sh post-tool-use-write.json
rc=1
[ "$CODE" -eq 0 ] && [ -f "$DATA/last-verdict.json" ] && rc=0
check "sync-run unconfigured -> still runs sync (no config gate)" "$rc" "exit $CODE out=$OUT"

# The gate likewise runs sync unconditionally (inSync -> allow).
fresh_data
unconfigure
STUB_VERDICT="$ROOT/fixtures/verdict-inSync.json" \
  run_hook sync-gate.sh pre-tool-use-git-push.json
rc=1
[ "$CODE" -eq 0 ] && ! contains "$OUT" 'deny' && rc=0
check "sync-gate unconfigured -> runs sync, allows on inSync" "$rc" "exit $CODE out=$OUT"

# status-context is read-only: it never runs sync; it advises that setup is automatic.
fresh_data
unconfigure
run_hook status-context.sh user-prompt-submit.json
contains "$OUT" 'set up'
check "status-context unconfigured -> advisory (auto-configures)" $?

echo "== side effects =="
rc=1
[ -f "$DATA/hook-events.log" ] && rc=0
check "hook-events.log written" "$rc" "expected $DATA/hook-events.log"

echo
printf 'L1: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
