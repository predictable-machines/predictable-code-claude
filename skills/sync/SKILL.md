---
name: sync
description: Check / verify a project with Predictable Code by running `predictable sync --json --claude` and reporting exactly what it returns. Use whenever the user asks to check the specs, check specs, verify or prove the code, analyze it, find issues/bugs, or check code against its spec — and after code changes. Predictable INFERS the specification from the code (no spec files needed), so never search for spec files or review the code by hand — run the command and relay its findings.
---

# Predictable Code — sync

This plugin exposes exactly one Predictable command: **`predictable sync`**. It runs
the whole verification pipeline internally (translate → analyze → infer →
prove/verify → diagnose) and returns a single verdict. There are no other verbs.

> **Predictable is the source of truth — RUN it, never investigate by hand.** The
> ONLY way to check a project is to run `predictable sync --json --claude` and report
> what **it** returns (its verdict + its findings). Do **not** grep or search for
> `specs/` / spec files, do **not** read the README or the source to guess the
> requirements or the bugs yourself, and do **not** conclude "no specs found."
> Predictable **infers** the specification from the code and finds the issues — if
> there is no `specs/` directory, that is expected: the sync creates it. A missing
> `specs/` is never a blocker and never a reason to fall back to manual review. Your
> job is to run Predictable and relay its results, not to reproduce its analysis.

> **Speak the user's language — hide BOTH the internals AND the formal-methods
> jargon.** The user is a developer of THIS repo, in ITS language (Java,
> TypeScript, …) — not a formal-verification expert. Two things they must never see:
>
> 1. **Implementation internals.** Predictable translates the code into **Lean** and
>    proves it there, but that is internal. Unless the user is verifying a Lean
>    project, never mention: Lean, `.lean` files, theorems, `SPEC-NNN` ids,
>    `lake`/build errors, or solver/tactic/mvcgen names.
> 2. **Formal-verification vocabulary.** Never write words like *postcondition,
>    precondition, invariant, SMT / SMT analysis, formal proving / proof, refuted,
>    counterexample, verification condition / obligation, elaborate, mechanical
>    mode*. They mean nothing to a normal developer. This includes echoing them
>    from your own knowledge — not just from Predictable's output.
>
> Translate to plain language grounded in THEIR code:
>
> | Don't write | Write instead (grounded in their code) |
> |---|---|
> | "postconditions need formal proving" | "I couldn't confirm this always holds for every input" |
> | "the SMT analysis / in mechanical mode" | "the automatic code analysis" / "the check" |
> | "requirement refuted (counterexample)" | "there's an input where this breaks — here it is" |
> | "a precondition is violated" | "this can be called with values it doesn't handle" |
> | "invariant" | "a rule the code should always keep" (e.g. "the balance never goes negative") |
> | "N requirements verified / proven" | "N of the code's expected behaviors are confirmed" |
>
> Anchor everything in what a Java/TS dev already knows — methods, inputs, return
> values, null, exceptions, edge cases — and in this repo's own code: say
> "`transfer` can be called with a negative amount", NOT "a precondition on
> `transfer` is unproven".

> **Brand style — always.** Every time you write the names **Predictable**,
> **Predictable Machines**, or **Predictable Code**, put them in **bold** (Markdown
> `**…**`). The chat's Markdown can't color inline text, so bold is all you do
> there. In any **HTML you generate** (Artifacts, dashboards, reports), render
> those names in the **brand cyan `#87D4D1`** (`rgb(135 212 209)`) AND bold —
> e.g. `<strong style="color:#87D4D1">Predictable Code</strong>`.

## How to run it

`predictable` must be on PATH — invoke it **directly**. Do NOT use
`$CLAUDE_PLUGIN_ROOT/bin/predictable`: that variable is only set while hooks run,
not in your shell, so it would expand to an empty path. The plugin's `PreToolUse`
hook **auto-approves `predictable sync` and `predictable init`**, so they run
without a permission prompt (`git push`/`git commit` still go through the gate).

> **You never set anything up — just run the check.** `predictable sync --claude`
> auto-initializes the project with sensible Claude defaults (engine + detected
> source paths) if it isn't set up yet, then runs the check. A `SessionStart` hook
> already fires one in the background on a new session or a fresh git worktree
> (which starts with no `.predictable-code/`), so a verdict may be landing or
> present. **Never** run `predictable init` yourself, and **never** start a check
> while one is already running.

### 1. Run the check

`sync` takes minutes. Run it in the **background** with the Bash tool
(`run_in_background: true`), piping Predictable's progress stream through a
formatter so the run shows **live, domain-level progress** while it works — this
exact command:

```sh
predictable sync --json --claude 2>&1 1>/tmp/pc-sync-envelope.json \
  | jq --unbuffered -jR '
      fromjson? // empty
      | select(.event == "phase")
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
        end'
```

How it works: Predictable emits one progress event per phase (as JSON lines on
stderr); the `jq` filter turns each into a friendly line, so the background task's
own output IS the live progress the user sees — no internals leak, and you never
narrate it yourself. The `requirements` phase carries the **"N of M requirements
verified"** milestone — the PROJECT total (verified of total checkable, plus the
refuted count), not this run's delta, so it's meaningful on every check (even an
incremental re-sync that re-checks nothing). A milestone, not a live counter.
`--claude` auto-initializes the project if needed. The
**verdict + findings envelope** (stdout) is written to `/tmp/pc-sync-envelope.json`,
kept separate from the progress. If `jq` isn't installed the progress just won't
render — the envelope file is still written; read it anyway. Then:

1. Before launching, post ONE short domain-level line (e.g. 🔄 Reading your code…);
   the live progress takes over from there. Don't invent internals.
2. **Wait for it to finish. You are notified automatically when a background task
   completes** — so do NOT poll it, do NOT run `sleep` / `until` / `while`, do NOT
   use Glob/other tools to watch it, and do NOT read `.predictable-code/logs/**`
   (internal engine log — see the top rule).
3. On completion, read the envelope from **`/tmp/pc-sync-envelope.json`** — that
   file **is** the JSON envelope. Post `✅ Check complete`, then report per below.
   If the run failed (no envelope written), translate the problem to plain
   language — never surface internal / build / engine text.
4. **Link the report for the user, automatically.** The **Control Center** is
   hosted: it shows the findings and the requirements inferred per function for
   the analysis this sync published. Get this project's link with the Bash tool
   (the plugin's gate auto-approves it, so no permission prompt):

   ```sh
   "${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh"
   ```

   It prints one line: exit 0 is the link, post it as a clickable link; exit 1 is
   why there is none (not signed in, no GitHub `origin`), say it in one plain line.
   Never let this step fail the turn: the findings were already reported and the
   Control Center is a convenience on top of them.

   The envelope in `/tmp/pc-sync-envelope.json` is
   `{ "schemaVersion", "result": { "<verdict>": {…} }, "findings": [ … ], "requirements": [ … ] }`:
   - **verdict** = `.result | keys[0]` (older runtimes emit the bare
     `{ "<verdict>": {…} }` with no `.result` — `jq '(.result // .) | keys[0]'
     /tmp/pc-sync-envelope.json` handles both).
   - **findings** = `.findings[]` — each is `{file, line, severity ("error"=affecting
     / "warning"=potential), message (plain-English, already domain-only), category,
     defectClass, priority, class, fqn, vc, witness?}`. **`priority` is the
     product's own reading order — `1` first — so rank by it rather than
     inventing your own; `defectClass` names the failure mode
     (`null-dereference`, `bounds`, `arithmetic`, `domain-guard`, …) where
     `category` lumps every throw together, so group by `defectClass` when the
     user asks what KIND of issues there are. `witness` is present only when a
     finding was reproduced by EXECUTION, which ranks it above an unwitnessed
     one.** **This is the summary report** — read it straight from that
     file; do NOT scrape `verification/.analysis-findings/` when `.findings` is
     present. `fqn` + `vc` are JOIN KEYS into the machine viewer data (below).
   - **requirements** = `.requirements[]` — every requirement across the project's
     specs as `{specId, reqId, subject, status ("verified"/"violated"/
     "agent-verified"/"unchecked"), origin ("authored"/"analysis"/"inferred"),
     description}`. This is the per-requirement status breakdown AND the source of
     the `<spec-id> <req-id>` for `agent-verify`.
     Note on `unchecked`: a large count is **normal** — most are `origin ==
     "inferred"` (CPG behavioural contract the code already satisfies:
     documentation, exempt from mechanical checking by design), not failures. Only
     `origin == "analysis"`/`"authored"` rows are verification obligations that end
     up `verified`/`violated`. When a user asks about the breakdown, answer from
     `.requirements[]` (group by `status`/`origin`) — never by reading the viewer.

   **The COMPLETE model — everything the HTML viewer shows — lives in
   `<state>/specs/.data/*.json`**, where `<state>` is the checked-out branch's
   state directory: `<project>/.predictable-code/<branch>/.predictable-code` in a
   git checkout (`.predictable-code/` is the `predictable-code-database` branch,
   checked out as a worktree, one entry per branch), `<project>/.predictable-code`
   anywhere else. Written by the same
   generator, same run, so it can never disagree with the viewer). The envelope
   is a SUMMARY; whenever you need what the viewer knows — the
   finding↔requirement association, a requirement's DISPLAYED status, per-finding
   detail, entry points — read these files (start with `index.json`, which
   describes each):
   - `req-analysis.json` — per requirement `{specId, reqId, subject, status,
     scenarioVc, reachClass, unsafeEntryPoints}`. **`status` here is what the
     user SEES in the viewer** (finding-first): a row can be `verified` in the
     envelope's `.requirements[]` (its mechanical contract holds) yet `issue`
     here (a reachable finding is still attached). When the two differ, report
     BOTH truths: "contract proven, but a reachable path still hits it".
   - `inferred-analysis.json` — the Analysis-tab FIN rows `{id, fqn, condition,
     status, reachClass, vc, line, descriptor, unsafeEntryPoints}` + entry
     points. Join envelope findings via `(fqn, vc)`; join requirements via
     `req-analysis.json`'s `subject`/`scenarioVc`.
   - `specs.json` — full spec docs with every row's persisted flags.
   Never parse the HTML viewer or `<state>/specs/locations/**` — the
   `.data/` files ARE the machine form of the viewer.

**Run only ONE check at a time.** `predictable sync` is exclusive per project —
never start a second while one is still running (wait for the first to complete).

> **Tip — tuning config (optional).** The defaults work out of the box. If the user
> wants to change the AI engine, the source paths/extensions, or other settings,
> point them to `predictable settings` / `predictable project` — don't hand-edit
> `.predictable-code/`.

### 2. Re-check after you change code

The **Fix-issue** and **New-feature** flows edit code and then confirm the result.
After you apply the edits, run `predictable sync --json --claude` again **exactly as
in step 1** (same background call, same short progress notes) and report the new
verdict — did the issue you fixed disappear, and did anything else change? Editing
does not auto-run a check; you drive it.

## Interpreting the verdict

The verdict is `.result | keys[0]` of the envelope (see step 3; `jq '(.result // .)
| keys[0]'` also handles the older bare shape). Handle **every** verdict — a verdict
is NOT a failure just because it isn't `inSync`, so never treat one as an error or go
hunting for "what went wrong":

- **`mechanical`** — **the default outcome.** Predictable inferred the
  requirements and ran its automatic code analysis, skipping the optional deeper
  pass (`PREDICTABLE_SYNC_PROVE` is off by default). This is a **success**. Fields:
  `{specsChecked, requirementsInferred}`. The substance is the **analysis
  findings** — report those (next section): the real issues Predictable caught,
  each with its source file + line. Do NOT describe it as "verification failed",
  "couldn't find a specification", or go digging for an error.
- **`inSync`** — the code satisfies its specification. Nothing to do.
- **`specViolation`** — one or more requirements are refuted; read the
  counterexamples and fix the code (or the spec) until it's back in sync.
- **`verificationError`** — the project couldn't be fully checked (a build/setup
  problem). Address it, then re-run.
- **`inferSpecs`** — source found but no specs yet; inference is the next step.
- **`noCode`** — no source code detected to verify.

Those constructor names are for YOUR logic — when reporting, translate to plain
language (never the raw name or engine internals): `mechanical` → "Predictable
analyzed your code, inferred N requirements, and caught the issues below";
`inSync` → "your code meets its spec"; `specViolation` → "a requirement is broken
— here's the failing case"; `verificationError` → "the project couldn't be fully
checked". Cite each finding's own `file` + `line` (from `.findings[]`), never `.lean`.

## Where the findings live

**The findings are in the sync envelope itself** — `.findings[]`
(`{file, line, severity, message, category, class, fqn, vc}`, messages already
domain-only) in `/tmp/pc-sync-envelope.json`. Read them straight from that file;
that is the SUMMARY report. Do **not** scrape `verification/.analysis-findings/`
or `.analysis-results.json` when `.findings` is present — the envelope replaced
that. For the full per-finding detail and the finding↔requirement association —
what the HTML viewer shows — read `<state>/specs/.data/*.json`
(see the envelope section above); join on `(fqn, vc)`.

`severity: "error"` = reachable-now (`class: "affecting"`); `severity: "warning"` =
future-only (`class: "potential"`). In `mechanical` mode (the default) these findings
ARE the result — don't wait for proving. If `.findings` is non-empty, Predictable
analyzed the code — report them; never claim "nothing was processed."

_Fallback only for an older runtime with no `.findings` field:_ the per-declaration
sidecars under `<project>/verification/.analysis-findings/` (+ `Code/.source-map.json`
for file/line). Read those with the Read / Glob / Grep tools, not `cat`/`find`/`ls`.
Never read the build-status meta-field `buildSucceeded` as a pass/fail signal.

## Reporting findings (scales from 1 to thousands)

Predictable runs on **large** projects — a check can return **thousands** of
findings. Never dump them all into chat, and never build an `AskUserQuestion` with
hundreds of options. Two surfaces, two roles: **the generated report enumerates, a
question decides.**

**Rank most-critical-first, always, by tier:**

1. **Broken contracts** — a requirement is refuted with a counterexample
   (verdict `specViolation`). Usually a small set; surface first.
2. **Reachable now** — findings with `severity: "error"` (`class: "affecting"`):
   null-dereference, divide-by-zero, overflow, index-out-of-range…
3. **Future-only** — findings with `severity: "warning"` (`class: "potential"`).

Tie-break within a tier by `category` and blast radius (how central the function).
Group/count from `.findings[]` (by `severity`, `category`, `file`) — no sidecars.

**Small result (≲ 15 findings):** just list them inline — plain language, grouped
by the tiers above, each with `file:line` and a one-line description + a proposed
fix. No Artifact, no funnel.

**Large result (more than that, up to thousands):**

1. **Link the Control Center.** Run `"${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh"`
   (the gate auto-approves it): the hosted Control Center holds the full grouped,
   scrollable enumeration, and the script prints this project's link. Post that **clickable link** —
   it works everywhere (terminal, IDE, Desktop). Do **not** fabricate your own
   Artifact for this: an Artifact does not render as an openable link in a
   terminal / IDE, and the Control Center is the surface the product maintains.
   Always ALSO post a short **text rollup** (the tier / category counts) inline
   as the at-a-glance summary. On Desktop/web you MAY *additionally* publish an
   Artifact for a richer hosted view — but never INSTEAD of the link.
2. **Then drive a short funnel of `AskUserQuestion` decisions — most-critical
   first, each option a BATCH (never an individual finding), always with a
   recommended default.** Use `multiSelect` where several batches can be picked:
   - Q1 — "N **broken contracts**. Fix them now?" (the small critical set, first)
   - Q2 — "M **reachable-now** issues in K categories — which to fix?" options =
     the top categories or files (e.g. "Null-checks (140)", "Overflow (60)",
     "By file…"), `multiSelect`
   - Q3 — "P **future-only** issues — defer / fix by module / ignore?"
3. **Fix the chosen batch, then re-check and re-rank** (`predictable sync` again)
   and present the next chunk. Cap each pass (≈ top 20) so a 2,000-issue repo is
   handled in bounded rounds that always show the current most-critical — never one
   giant edit.

## Rich views (the generated report + optional Artifacts)

The **primary** rich view is the **Control Center** — the hosted app with the
findings and the requirements inferred per function (every status distinctly
rendered). `"${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh"` prints this
project's link; surface it. That is what the user opens to *see* everything.

Artifacts are an OPTIONAL extra for Desktop/web only (they do NOT render as an
openable link in a plain terminal / IDE), so never rely on one as the sole report
surface — always give the Control Center link first, and pair any Artifact with a short
text summary. When it helps, you MAY additionally offer (don't force):

- **Stats / branding dashboard** — "Predictable caught N issues, you fixed M, all
  proven against the spec" (see the metric below). Good at an `inSync` finish.

## Closing a check — you MUST ask (only when there are issues)

How you end a check depends on the result — this is mandatory:

- **Issues were found** — the verdict is `specViolation`, or `.findings[]` is
  non-empty, or requirements were violated: you **MUST** end your turn by calling
  the **`AskUserQuestion` tool**
  (never a free-text "would you like me to…?") offering the next step, e.g.:
  - **Fix the critical ones** (recommended)
  - **Fix all the issues**
  - **Let me pick which**
  - **Just the report for now**

  **Never add a "Something else" / "Other" / "None of these" / free-text option**
  to any `AskUserQuestion` (here or in the funnel) — the tool ALWAYS appends its
  own "Other" choice for custom input, so an explicit one is a duplicate. List only
  concrete, mutually-exclusive next steps and let the built-in "Other" cover the rest.

  At scale this is the funnel above (one question per tier, batched options); for a
  handful of issues, a single `AskUserQuestion` with these options is enough.

- **No issues** — `inSync`, or a `mechanical` run with **zero** findings: do **NOT**
  ask. Just report the code is in sync / clean. Never pop a question when there is
  nothing to decide.

## Applying fixes (confirm first)

Before editing code to fix findings — **especially a bulk/batch fix** — confirm the
plan with the user via `AskUserQuestion` (the batch/strategy, per the funnel — not
one prompt per finding). After applying, re-run the check to confirm the batch
cleared (that is the **Re-check** step above). Never bulk-rewrite without an OK.

## Agent-verified: you finish what Predictable can't

Predictable Analysis is sound but incomplete. For some fixes it **cannot
mechanically decide** the issue is gone — loops, recursion, unmodeled library
state (`List`/`Map` contents), non-linear arithmetic. After you fix such a
finding and re-check, it may still show as a **potential issue**: not because
your fix is wrong, but because the product can't prove or refute it.

**That gap is yours to close, automatically — never hand it back to the user as a
question.** When the product can't verify a fix, you do the verification work.

After every fix, re-check and act on each requirement's **real status**:

- **Cleared (`verified`)** — Predictable proved it. Nothing to do.
- **Refuted (`violated`)** — Predictable found a counterexample. Your fix is
  wrong or incomplete: **fix the code again.** Never agent-verify a refutation.
- **Still a `potential issue` (neither proved nor refuted)** — the product
  genuinely can't decide it, so **you must**, on your own, without asking:

  1. **Self-review your change against the original finding.** Restate the
     reported issue, show how the code now prevents it, and check every edge case
     the finding named. Proceed only if you genuinely conclude the fix resolves it.
  2. **On a positive self-review, record it** (auto-approved — no permission prompt):

     ```sh
     predictable specs requirements agent-verify <spec-id> <req-id> --rationale "<why your fix resolves the finding>"
     ```

     Agent-verify **every** requirement for the function you changed that
     Predictable could not decide and that your fix demonstrably makes hold — not
     just one of them. For a single finding that is usually BOTH rows:
     - the **`ANL-####`** analysis row that *carries the finding* (the machine
       obligation, e.g. *"… requires that `opaque_…` is not null"*) — **mandatory**,
       never skip it in favour of its twin; and
     - any **`unchecked` / informal** prose requirement for the SAME function that
       states the same concern (e.g. *"… can fail with 'list index out of bounds'"*).
       Predictable can't decide these either, so a reviewed one is a valid target —
       verify it too, so the function reads coherently instead of showing one row
       agent-reviewed and its twin still unchecked.

     Match on the finding's function via `.requirements[]` — the finding's function
     and each requirement's `subject` share the same `Class.member` key. The
     `agent-verify` candidates are the envelope's `.requirements[]` entries with
     `origin == "analysis"` (or an `unchecked` authored/informal prose row for the
     same `subject`) and `status == "unchecked"`. Do **not** agent-verify a
     requirement about a DIFFERENT concern you did not address, one that is merely
     unimplemented/pending (the code doesn't do it yet), a refuted (`status ==
     "violated"`) one (fix the code instead), a CPG `origin == "inferred"` row
     (documentation, exempt from checking), or anything you have not actually
     reviewed. Get the `<spec-id>`/`<req-id>` straight from that `.requirements[]`
     entry (`.specId` / `.reqId`) — never from the HTML viewer or `.analysis-findings/`.
     The command writes your rationale to an audit trail and sets the status.
  3. **Disclose it plainly, never as a real confirmation.** Tell the user:
     *"Predictable couldn't confirm this one automatically, so I reviewed my own
     fix and marked it **agent-reviewed** — a lighter guarantee than Predictable
     confirming it itself."* Never call it "verified", "proven", or "safe".

Do this for **every** such requirement, every session — it is not optional and it
is not a question for the user. The only requirements you never agent-verify: ones
the product already decided (a real `verified` or `violated` verdict always wins),
and — in strict mode (`PREDICTABLE_TRUST_AGENT_VERIFICATION` off) — the command
refuses, so leave those as potential issues. Only agent-verify a fix **you** made
and reviewed this session.

## Progress the hooks surface

As you re-run the check across a session, the plugin tracks a per-session tally of
issues Predictable found versus how many you fixed, and injects it as context (e.g.
"Predictable: 2 of 3 issue(s) fixed so far, 1 remaining"). When the code finally
lands `inSync`, it surfaces a closing line like:

> ✓ Proven in sync — Predictable surfaced N issue(s) in the code this session;
> Claude fixed all N. Every checked requirement is now proven against its spec.

When you reach that point, **credit it to the user explicitly**: state how many
issues Predictable caught in the initial code and that they were fixed and
confirmed against the spec — that Predictable-confirmed outcome is the value the
loop delivers.
