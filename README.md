# predictable-code-claude

The [Claude Code](https://code.claude.com) plugin for **Predictable Code** —
spec-driven formal verification in the loop. It turns any project you open into a
closed verification loop: you edit code, Predictable re-translates / analyzes /
verifies it against its spec, and lifecycle hooks feed the verdict back to the
agent.

The plugin exposes **exactly one command — `predictable sync`** — which runs the
whole pipeline internally (translate → analyze → infer → prove/verify →
diagnose) and returns a single verdict. No other verbs, no MCP server, and
**zero configuration**.

> This repo contains **no Predictable source code** — only the plugin
> (manifest, hooks, scripts, one skill). The compiled runtime is downloaded on
> first run from a token-gated, artifacts-only distribution repository. The
> Predictable source stays private.

## Install

```sh
claude plugin marketplace add predictable-machines/predictable-code-claude
claude plugin install predictable-code@predictable-machines
```

On first session the `SessionStart` hook downloads the per-platform runtime
bundle (the `predictable` CLI + `predictable_java_direct` + pinned `z3` +
relocatable Lean toolchain + prebuilt `.lake` oleans) into the plugin's data
directory. This requires a distribution token:

```sh
export PREDICTABLE_DIST_TOKEN=<your-token>
```

The token unlocks only the compiled runtime — it grants no access to any source.
Without it, the plugin degrades gracefully (a `systemMessage`, never a broken
session).

## What it does

| Surface | Behavior |
| :-- | :-- |
| **Skill** `/predictable-code:sync` | Runs `predictable sync` and interprets the verdict + findings. |
| **`SessionStart`** | Ensures the runtime is installed; injects the last verdict as context. |
| **`UserPromptSubmit` / `PreCompact`** | Re-injects the last verdict so the agent always knows the sync state. |
| **`PreToolUse`** (Bash `git push`/`git commit`) | Runs `sync` synchronously and **blocks** the command unless the project is `inSync`. |
| **`Stop` / `SubagentStop`** | Advisory turn-end `sync` (skipped if one is already running) so the agent keeps working toward an in-sync state. |

Edits do **not** trigger a sync: the skill runs its own `predictable sync` after
changing code, and two syncs on one project at once are never allowed — the hook
skips when one is already in flight.

Everything is advisory except the **pre-push/commit gate**, the one hard block.

The `PreToolUse` hook also **auto-approves the plugin's own `predictable sync`**
command, so the agent runs it without a permission prompt (only `sync` is
auto-approved — `git push`/`git commit` still go through the gate, and every
other command falls through to the host's normal permission flow).

## First run in a project

`predictable sync` needs the project initialized — otherwise it drops into an
interactive setup wizard that can't be driven headlessly. The `sync` skill
handles this: it checks for `.predictable-code/project.json` and, if missing,
runs a one-time **non-interactive** setup —
`predictable init "<name>" --adapter claude --accept-config-suggestions` — asking
you which AI engine to use when it isn't obvious. Until the project is set up the
hooks stay quiet (they advise running the skill instead of launching the wizard),
so nothing ever hangs on a prompt.

## The verdict

`sync --json` prints a `SyncResponse` as a single-key object; the key is the
verdict:

- `inSync` — code satisfies its spec.
- `specViolation` — one or more requirements are refuted (counterexamples in
  `verification/.analysis-results.json`).
- `verificationError` — the project did not verify cleanly.

## Progress & proof (the value it surfaces)

Every `sync` is recorded in a per-session tally (reset each new session). As you
work, the hooks inject the running story as context:

- while fixing — `Predictable: 2 of 3 issue(s) fixed so far, 1 remaining`
- when it lands — `✓ Proven in sync — Predictable surfaced N issue(s) in the code
  this session; Claude fixed all N. Every checked requirement is now proven
  against its spec.`

The counts are ground truth from the SMT verdict (`verificationError` →
real errors + refuted contracts; `inSync` → residual refutations), not
heuristics — so "Claude fixed N issues Predictable caught, and the result is
formally proven against its spec" is a claim you can stand behind. The raw
timeline is in `$PLUGIN_DATA/session-history.jsonl` and `hook-events.log`.

## Layout

```
.claude-plugin/plugin.json       # manifest — no userConfig, no mcpServers
.claude-plugin/marketplace.json  # marketplace catalog (source: ./)
hooks/hooks.json                 # command hooks (portable across hosts)
scripts/                         # bootstrap, sync-run, sync-gate, status-context, doctor, lib
bin/predictable                  # wrapper → downloaded runtime (env-primed), dev fallback
skills/sync/SKILL.md             # the single skill
fixtures/                        # captured hook inputs + verdict samples (tests)
tests/                           # L1 hook-contract + L2 surface/privacy tests
kit.json                         # pinned runtime version + dist coordinates
```

## Develop & test

No API key or runtime bundle is needed for the core gate:

```sh
make lint                  # shellcheck every script
make test-plugin           # L1 (hook contract) + L2 (surface + privacy)
```

Bundle-dependent layers (need `PREDICTABLE_DIST_TOKEN`, and a key for L5):

```sh
make test-plugin-doctor            # L4 configuration self-check
make test-plugin-mcp PROJECT=<clone>   # L3 'predictable sync --json' contract
make test-plugin-e2e-claude        # L5 headless end-to-end (ANTHROPIC_API_KEY)
```

## Privacy

- No plugin file contains Predictable source; CI fails the build if any
  `.lean` / `lakefile` / `packages/` path is ever tracked.
- The runtime bundle lives in a separate artifacts-only repo and is fetched with
  a distribution token that has no source access.

## License

Apache-2.0. See [LICENSE](LICENSE).
