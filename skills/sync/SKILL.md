---
name: sync
description: Check the current project against its specification with Predictable Code — runs `predictable sync` (translate → analyze → infer → prove → diagnose) and reports the verdict. Use when the user asks to verify, prove, or check code against its spec, or after code changes that should stay in sync.
---

# Predictable Code — sync

This plugin exposes exactly one Predictable command: **`predictable sync`**. It runs
the whole verification pipeline internally (translate → analyze → infer →
prove/verify → diagnose) and returns a single verdict. There are no other verbs.

> **Speak the user's language — never leak Predictable's internals.** Predictable
> works by translating the code into **Lean** and proving it there, but that is an
> INTERNAL implementation detail. Unless the user is verifying a Lean project,
> **never** mention to the user: Lean, `.lean` files, theorems, `SPEC-NNN` ids,
> `lake`/build errors, solver/tactic/mvcgen names, or the raw verdict constructor
> names. Describe everything in terms of *their* source language (Java, …), their
> **specification**, their **functions** and **requirements**. E.g. say "one
> requirement couldn't be checked", not "a Lean build issue on SPEC-034".

## How to run it

`predictable` must be on PATH — invoke it **directly**. Do NOT use
`$CLAUDE_PLUGIN_ROOT/bin/predictable`: that variable is only set while hooks run,
not in your shell, so it would expand to an empty path. The plugin's `PreToolUse`
hook **auto-approves `predictable sync` and `predictable init`**, so they run
without a permission prompt (`git push`/`git commit` still go through the gate).

### 1. Ensure the project is set up (once per project)

`predictable sync` needs the project initialized. If it isn't, `sync` launches an
interactive setup wizard that **cannot** be driven from here — so always check
first, from the project root:

```sh
test -f .predictable-code/project.json && echo configured || echo needs-setup
```

If it prints `needs-setup`, initialize it **non-interactively** (never run bare
`predictable init` — that is interactive):

1. **Choose the AI engine.** Default to **`claude`** (you are running inside
   Claude Code). Ask the user first only if they might prefer `copilot` or
   `opencode`, or if they say so.
2. Run it, using the repository/folder name as the project name:

   ```sh
   predictable init "<project-name>" --adapter <engine> --accept-config-suggestions
   ```

   `--accept-config-suggestions` auto-accepts the detected source paths so no
   prompt appears. Then confirm `.predictable-code/project.json` now exists.

If setup reports a problem, or needs a choice you cannot safely infer, **ask the
user** before continuing rather than guessing.

### 2. Run sync — with a couple of progress notes

`sync` takes minutes and `--json` prints nothing until it finishes. Run it in the
**background** with the Bash tool (`run_in_background: true`) — this exact command:

```sh
predictable sync --json
```

Then, simply:

1. Post one or two short, emoji-led, domain-level lines so the user knows it's
   working — nothing derived from internals:
   - 🔄 Reading your code…
   - 🧪 Verifying your code against its spec — this takes a few minutes…
2. **Wait for it to finish. You are notified automatically when a background task
   completes** — so do NOT poll it, do NOT run `sleep` / `until` / `while`, do NOT
   use Glob/other tools to watch it, and do NOT read `.predictable-code/logs/**`
   (internal engine log — see the top rule).
3. On completion, its captured stdout **is** the `SyncResponse` JSON. Post
   `✅ Check complete`, then report per below. If the run failed, translate the
   problem to plain language — never surface internal / build / engine text.

## Interpreting the verdict

`sync --json` prints a `SyncResponse` as a single-key object `{ "<verdict>": { … } }`
(get the key with `jq -r 'keys[0]'`). Handle **every** verdict — a verdict is NOT
a failure just because it isn't `inSync`, so never treat one as an error or go
hunting for "what went wrong":

- **`mechanical`** — **the default outcome.** Predictable inferred the
  requirements and ran its SMT analysis, but skipped formal proving
  (`PREDICTABLE_SYNC_PROVE` is off by default). This is a **success**. Fields:
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
checked". Cite the user's own source file + line (from `.source-map.json`), never
`.lean`.

## Where the details live

After a run, inspect these under `<project>/verification/`:

- `.analysis-results.json` — the SMT analysis results (per-function findings).
- `.analysis-findings/` — per-declaration finding sidecars.
- `Code/*.lean` — the translated model.
- `Code/.source-map.json` — maps each finding back to its source file + line range.

**Inspect them with the Read / Glob / Grep tools, not `cat` / `find` / `ls` via
Bash.** File reads through those tools don't trigger a Bash permission prompt, so
the loop stays smooth; shelling out for the same thing makes the user approve
each command. Likewise, read `sync`'s JSON from its own stdout directly — don't
redirect it to a temp file and then `cat` the temp file back.

Report the verdict in plain language, then summarize the concrete findings in
`.analysis-findings/` — the `verify_*` files are spec-requirement checks, the
`analyze_*` files are general SMT analysis — as the **real issues Predictable
caught**, each mapped to its source file + line via `.source-map.json`. Propose
fixes for the genuine ones. In `mechanical` mode (the default) these findings ARE
the result — don't wait for proving or treat their absence-of-proofs as a
problem.

**Do not read build-status meta-fields in `.analysis-results.json` as a
pass/fail signal.** `buildSucceeded: false` does NOT mean "nothing was analyzed"
or "the code couldn't be translated" — it usually just means the mechanical
translation fell back to the LLM. What matters is the findings: use
`findingsAffecting` / `findingsPotential` and the `.analysis-findings/` sidecars.
If findings exist, Predictable analyzed the code — report them; never claim "0 of
N functions processed" when `results` is non-empty.

## Progress the hooks surface

As you edit and `sync` re-runs, the plugin tracks a per-session tally of issues
Predictable found versus how many you fixed, and injects it as context (e.g.
"Predictable: 2 of 3 issue(s) fixed so far, 1 remaining"). When the code finally
lands `inSync`, it surfaces a closing line like:

> ✓ Proven in sync — Predictable surfaced N issue(s) in the code this session;
> Claude fixed all N. Every checked requirement is now proven against its spec.

When you reach that point, **credit it to the user explicitly**: state how many
issues Predictable caught in the initial code and that they were fixed and
formally proven against the spec — that verified-by-Predictable outcome is the
value the loop delivers.
