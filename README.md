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
| **`SessionStart`** | Ensures the runtime is installed **and the project is initialized** (headless), kicks off a first check **in the background**, and injects the last verdict as context. Self-configures fresh sessions and worktrees with no user action. |
| **`UserPromptSubmit` / `PreCompact`** | Re-injects the last verdict so the agent always knows the sync state. |
| **`PreToolUse`** (Bash `git push`/`git commit`) | Runs `sync` synchronously and **blocks only on a broken requirement** (`specViolation`). Every other verdict is advisory (warn, don't block). |
| **`Stop` / `SubagentStop`** | Advisory turn-end `sync` (skipped if one is already running) so the agent keeps working toward an in-sync state. |

Edits do **not** trigger a sync: the skill runs its own `predictable sync` after
changing code, and two syncs on one project at once are never allowed — every hook
skips when one is already in flight.

Everything is advisory except the **pre-push/commit gate**, and even that blocks
only on a genuine `specViolation`.

The `PreToolUse` hook also **auto-approves the plugin's own `predictable sync`**
command, so the agent runs it without a permission prompt (only `sync` is
auto-approved — `git push`/`git commit` still go through the gate, and every
other command falls through to the host's normal permission flow).

## Worktrees & surfaces

**Git worktrees.** A new worktree is a fresh checkout from `origin/HEAD` — it does
**not** carry uncommitted or untracked files, and `.predictable-code/` is gitignored
so it is never copied over. That is fine: the `SessionStart` hook re-initializes and
re-checks each worktree automatically. If you would rather a worktree **inherit** the
existing config (and skip re-init), add a [`.worktreeinclude`](https://code.claude.com/docs/en/worktrees)
to your repo root with:

```text
.predictable-code/project.json
```

Do **not** configure a `WorktreeCreate` hook for this — that hook *replaces* git
worktree creation entirely and disables `.worktreeinclude`; it is meant for non-git
VCS, not setup.

**Surfaces.** The plugin's command hooks + the `predictable` runtime need a local
shell, so the loop runs in the **terminal CLI, the desktop app, and the IDE
extensions** (VS Code / JetBrains run the CLI underneath). The **web app**
(claude.ai/code) is a sandbox with no local shell or binary, so the sync loop does
not run there — the plugin degrades to nothing rather than erroring. Artifact views
(findings / stats / specs dashboards) render in the desktop and web apps; in a plain
terminal they appear as a link, so the skill always pairs one with a text summary.

## First run in a project

The plugin never sets anything up itself — it just runs **`predictable sync --json
--claude`**. The `--claude` flag makes Predictable **auto-initialize** the project
with sensible Claude defaults (engine + deterministically-detected source paths) if
it isn't set up yet, then run the check. This is headless and **never launches the
setup wizard**, so a fresh session, a git worktree, or any other checkout Claude
lands in self-configures with no user action and nothing ever hangs on a prompt. If
the runtime isn't available, the hooks step aside with a notice rather than blocking.

To change the engine, source paths, or other settings afterwards, use
`predictable settings` / `predictable project` (no need to hand-edit
`.predictable-code/`).

## The verdict

`sync --json` prints a `SyncResponse` as a single-key object; the key is the
verdict:

- `inSync` — code satisfies its spec.
- `specViolation` — one or more requirements are refuted (counterexamples in
  `verification/.analysis-results.json`).
- `verificationError` — the project did not verify cleanly.

## Progress & proof (the value it surfaces)

A check takes minutes, so it streams **live, domain-level progress** while it runs
(reading your code → analyzing → working out the specification), from Predictable's
`--json` progress stream — no raw internals, just where it is in the pipeline.

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
