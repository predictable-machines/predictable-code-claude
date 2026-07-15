# Turn Predictable's `sync --json` NDJSON progress stream (one event per line on
# stderr, #1237) into friendly, domain-only progress lines. The sync skill runs:
#
#   predictable sync --json --claude 2>&1 1>ENVELOPE.json \
#     | jq --unbuffered -jR -f scripts/progress.jq
#
# stdout (the verdict + findings envelope) is redirected to ENVELOPE.json; stderr
# (this NDJSON stream) is piped here, so the visible output of the run IS the live
# progress. Non-JSON lines (e.g. a schema-drift warning) and unknown phases are
# dropped. Domain-only — never leak Lean/build vocabulary (#1238).
#
# SKILL.md mirrors this filter inline because the skill's shell can't path to this
# file; this file is the tested source of truth — keep the two in sync.
fromjson? // empty
| select(.event == "phase")
| ({ translation: { start: "🔄 Reading your code…\n" },
     analysis:    { start: "🔎 Analyzing your code for issues…\n",
                    done:  "✓ Analyzed \(.functions // "?") function(s) — \(.findings // 0) potential issue(s)\n",
                    error: "⚠️ Analysis hit a snag — continuing…\n" },
     inference:   { start: "🧪 Working out the specification…\n",
                    done:  "✓ Specification inferred\n" } }[.phase][.state]) // empty
