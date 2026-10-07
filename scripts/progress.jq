# Turn Predictable's `sync --json` NDJSON progress stream (one event per line on
# stderr, #1237) into friendly, domain-only progress lines. The sync skill runs:
#
#   predictable sync --json --claude 2>&1 1>ENVELOPE.json \
#     | jq --unbuffered -jR -f scripts/progress.jq
#
# stdout (the verdict + findings envelope) is redirected to ENVELOPE.json; stderr
# (this NDJSON stream) is piped here, so the visible output of the run IS the live
# progress. Unknown phases are dropped, and so are non-JSON lines (a schema-drift
# warning, a log line) — EXCEPT one Predictable addresses to the person,
# `Predictable Code: …`, which is how the CLI says why it did not run: a checkout from
# before the database is refused with exit 1, no envelope, and one such line naming
# `predictable migrate`. Dropping it left a run that ended with nothing to read and no
# reason anyone could see. Domain-only — never leak Lean/build vocabulary (#1238).
#
# SKILL.md mirrors this filter inline because the skill's shell can't path to this
# file; this file is the tested source of truth, and the hook tests run both on the
# same input, so the two cannot drift apart unnoticed.
(fromjson? // {said: .})
| (select(.said? | strings | startswith("Predictable Code: ")) | "⚠️ \(.said)\n"),
  (select(.event? == "phase")
   | if .phase == "requirements"
     then (if (.checked // 0) > 0
           then "✓ \(.verified) of \(.checked) requirement(s) verified"
                + (if (.violated // 0) > 0 then " · \(.violated) refuted" else "" end) + "\n"
           else empty end)
     else ({ translation: { start: "🔄 Reading your code…\n" },
             analysis:    { start: "🔎 Analyzing your code for issues…\n",
                            done:  "✓ Analyzed \(.functions // "?") function(s) — \(.findings // 0) potential issue(s)\n",
                            error: "⚠️ Analysis hit a snag — continuing…\n" },
             inference:   { start: "🧪 Working out the specification…\n",
                            done:  "✓ Specification inferred\n" } }[.phase][.state]) // empty
     end)
