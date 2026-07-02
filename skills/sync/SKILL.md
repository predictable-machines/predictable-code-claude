---
name: sync
description: Check the current project against its specification with Predictable Code — runs `predictable sync` (translate → analyze → infer → prove → diagnose) and reports the verdict. Use when the user asks to verify, prove, or check code against its spec, or after code changes that should stay in sync.
---

# Predictable Code — sync

This plugin exposes exactly one Predictable command: **`predictable sync`**. It runs
the whole verification pipeline internally (translate → analyze → infer →
prove/verify → diagnose) and returns a single verdict. There are no other verbs.

## How to run it

Invoke the bundled wrapper (it primes the runtime environment; falls back to a
`predictable` on PATH in dev):

```sh
"$CLAUDE_PLUGIN_ROOT/bin/predictable" sync --json
```

Run it from the project root — `sync` uses the project's `.predictable-code/`
directory and writes artifacts under `verification/`. Pass no flags: the plugin
is zero-configuration (default engine, default paths, default concurrency).

## Interpreting the verdict

`sync --json` prints a `SyncResponse` as a single-key object `{ "<verdict>": { … } }`.
The key is the verdict:

- **`inSync`** — the code satisfies its specification. Nothing to do.
- **`specViolation`** — one or more requirements are **refuted**. The code
  contradicts its spec. Read the counterexamples and fix the code (or, if the
  spec is wrong, the spec) until `sync` reports `inSync`.
- **`verificationError`** — the project did not verify cleanly (e.g. a
  translation or build failure). Address the reported error, then re-run.

Extract the verdict quickly with `jq -r 'keys[0]'`.

## Where the details live

After a run, inspect these under `<project>/verification/`:

- `.analysis-results.json` — the SMT analysis results (per-function findings).
- `.analysis-findings/` — per-declaration finding sidecars.
- `Code/*.lean` — the translated model.
- `Code/.source-map.json` — maps each finding back to its source file + line range.

Report the verdict to the user and, when it is not `inSync`, summarize the
refuted requirement(s) and the counterexample, then propose a fix.
