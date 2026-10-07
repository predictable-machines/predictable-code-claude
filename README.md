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
> (manifest, hooks, scripts, one skill). It runs the `predictable` CLI you
> install (below), or a compiled runtime it downloads from a token-gated,
> artifacts-only distribution repository. The Predictable source stays private.

## Install

### 1. The `predictable` CLI

Install it with the command the hosted Control Center shows under
**Settings › Connected machines**:

```sh
curl -fsSLO https://<control-center>/i/<code>/predictable-install.sh && bash predictable-install.sh
```

It installs Predictable Code and puts `predictable` on your `PATH` (open a new
shell, and start Claude Code from it, so the session sees it). With no runtime
bundle of its own, the plugin runs that `predictable` — `bin/predictable` falls
back to the one on `PATH` — so nothing else is needed.

**Alternative: the runtime bundle.** With a distribution token set, the
`SessionStart` hook downloads the per-platform runtime bundle (the `predictable`
CLI + `predictable_java_direct` + pinned `z3` + relocatable Lean toolchain +
prebuilt `.lake` oleans) into the plugin's data directory on the first session,
and uses it instead:

```sh
export PREDICTABLE_DIST_TOKEN=<your-token>
```

The token unlocks only the compiled runtime — it grants no access to any source.
With neither, the plugin degrades gracefully (a `systemMessage`, never a broken
session).

### 2. The plugin, in the repositories that should be analysed

Add the marketplace once:

```sh
claude plugin marketplace add predictable-machines/predictable-code-claude
```

then, from the root of each repository that should be analysed:

```sh
claude plugin install predictable-code@predictable-machines --scope local
```

**Choose the scope.** `claude plugin install` defaults to **user** scope, which
turns the plugin on in **every** repository you open with Claude Code — and its
hooks initialise Predictable Code there, sync it, and **publish** each analysis
(a push to origin's `predictable-code-database` branch). Install it per
repository instead:

| Scope | Recorded in | Who gets it |
| :-- | :-- | :-- |
| `--scope local` (recommended for yourself) | `.claude/settings.local.json`, not committed | you, in this repository |
| `--scope project` (recommended for a team) | `.claude/settings.json`, committed | everyone who opens this repository with Claude Code |
| `--scope user` (the default) | `~/.claude/settings.json` | you, in every repository |

For `--scope project`, declare the marketplace in the repository too
(`claude plugin marketplace add predictable-machines/predictable-code-claude --scope project`),
so a teammate's Claude Code can find the plugin it names.

Already installed at user scope? Remove it there
(`claude plugin uninstall predictable-code@predictable-machines --scope user`)
and install it with `--scope local` or `--scope project` in each repository that
should be analysed.

### A checkout from before the database

A repository whose code branch still tracks `.predictable-code/` (set up by an
earlier Predictable Code) is refused by `predictable sync` until it is migrated,
once:

```sh
predictable migrate
git push
```

`predictable migrate` makes one local commit that stops tracking
`.predictable-code/` (nothing is deleted) and moves the configuration to the
`predictable-code-database` branch; push that commit so every other checkout of
the branch gets it. Until then the hooks say so (see
[When a check does not run](#when-a-check-does-not-run)), and the agent is told
to run it.

## What it does

| Surface | Behavior |
| :-- | :-- |
| **Skill** `/predictable-code:sync` | Runs `predictable sync` and interprets the verdict + findings. |
| **Command** `/predictable-code:report` | Links this project in the hosted Control Center (findings + inferred requirements), or says why there is no link (not signed in, no GitHub `origin`). |
| **`SessionStart`** | Ensures the runtime is installed **and the project is initialized** (headless), kicks off a first check **in the background**, and injects the last verdict as context. Self-configures fresh sessions and worktrees with no user action. |
| **`UserPromptSubmit` / `PreCompact`** | Re-injects the last verdict so the agent always knows the sync state. |
| **`PreToolUse`** (Bash `git push`/`git commit`) | Runs `sync` synchronously and **blocks only on a broken requirement** (`specViolation`). Every other verdict is advisory (warn, don't block), and a sync that does not run never blocks — the gate says why. |
| **`Stop` / `SubagentStop`** | Advisory turn-end `sync` (skipped if one is already running) so the agent keeps working toward an in-sync state. |

Edits do **not** trigger a sync: the skill runs its own `predictable sync` after
changing code, and two syncs on one project at once are never allowed — every hook
skips when one is already in flight: when the runtime's sync lock (in the
checked-out branch's entry of the database) names a live process, or is still
being written.

Everything is advisory except the **pre-push/commit gate**, and even that blocks
only on a genuine `specViolation`.

### When a check does not run

A `predictable sync` that exits non-zero is never dropped. Every hook keeps the
sync's stderr apart from its JSON envelope and takes the CLI's own reason from it
— the last line that is not a progress event — for example a checkout from before
the database, refused with one line naming `predictable migrate`:

- the **pre-push/commit gate** allows the command (it blocks only on
  `specViolation`) and says it was not checked, and why;
- the **background** syncs (`SessionStart`, `Stop`) record the reason; the next
  turn end tells the **user** once per session, and every prompt tells the
  **agent**, with what to do about it, until a sync runs.

The `PreToolUse` hook also **auto-approves the plugin's own commands** — running
`predictable sync`, linking the Control Center (`scripts/control-center-url.sh`), and
recording an agent-reviewed fix (`predictable specs requirements agent-verify`) —
so the agent runs them without a permission prompt (`git push`/`git commit` still
go through the gate, and every other command falls through to the host's normal
permission flow).

## Worktrees & surfaces

**Git worktrees.** Everything Predictable keeps lives on one branch of your
repository, `predictable-code-database`, which `predictable` checks out at
`.predictable-code/` in each checkout (hidden from your code by
`.git/info/exclude`). A new worktree shares the repository, so its first sync opens
the same database — the configuration and every branch's analysis included — and an
analysis of a state some branch already has is reused rather than recomputed.
Nothing needs copying, and no `.worktreeinclude` or `WorktreeCreate` hook is needed.

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
