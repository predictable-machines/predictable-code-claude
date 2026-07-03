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

### 2. Run sync — and narrate progress with emojis

`sync` takes minutes and `--json` prints nothing until it finishes. Run it with
the **Bash tool's background mode** (`run_in_background: true`) — this exact
command, no other flags:

```sh
predictable sync --json
```

Do **NOT** append a shell `&`, and do **NOT** write a `sleep` / `until` / `while`
wait-loop — the harness blocks foreground sleeps; use the Bash tool's own
background polling to know when it finishes.

**Never read `.predictable-code/logs/**`.** That is Predictable's internal engine
log; it is full of implementation detail (the engine, solver, intermediate build
output) that is meaningless — and confusing — to the user, and it must never enter
this conversation. Take progress ONLY from domain-level signals:

- 🔄 Reading your code… (emit right after you launch it)
- 🧪 Verifying your code against its spec — this takes a few minutes…
- optionally, once results start landing, count the files in
  `.predictable-code/verification/.analysis-findings/` with the **Glob** tool and
  post `🧪 Analyzed N functions so far…` — a COUNT only, never their names/contents
- ✅ Check complete — preparing the report… (when the background task finishes)

Every line starts with its emoji. Keep it to a handful — inform, don't spam.

When the background task completes, its captured stdout **is** the `SyncResponse`
JSON — parse it and continue below. Do not surface any internal error text a
failed run might carry; translate to plain language (see the top rule).

## Interpreting the verdict

`sync --json` prints a `SyncResponse` as a single-key object `{ "<verdict>": { … } }`.
The key is the verdict:

- **`inSync`** — the code satisfies its specification. Nothing to do.
- **`specViolation`** — one or more requirements are **refuted**. The code
  contradicts its spec. Read the counterexamples and fix the code (or, if the
  spec is wrong, the spec) until `sync` reports `inSync`.
- **`verificationError`** — the project did not verify cleanly (e.g. a
  translation or build failure). Address the reported error, then re-run.

Extract the verdict quickly with `jq -r 'keys[0]'`. Those constructor names are
for YOUR logic — when reporting to the user, translate: `inSync` → "your code
meets its spec"; `specViolation` → "a requirement is broken — here's the case
that breaks it"; `verificationError` → "the project couldn't be fully checked".
Cite the user's own source file + line (from `.source-map.json`), never `.lean`.

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

Report the verdict to the user and, when it is not `inSync`, summarize the
refuted requirement(s) and the counterexample, then propose a fix.

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
