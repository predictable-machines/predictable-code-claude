.PHONY: help lint test-plugin test-plugin-hooks test-plugin-validate \
        test-plugin-doctor test-plugin-mcp test-plugin-e2e-claude

SHELL := /bin/bash

# Default: the fast, key-free, bundle-free gate that CI runs on every PR.
help:
	@echo "predictable-code-claude — the Claude Code plugin for Predictable Code"
	@echo ""
	@echo "No-key / no-bundle (run on every PR):"
	@echo "  make lint                 Run shellcheck over every script"
	@echo "  make test-plugin-hooks    L1: hook-contract tests (fixtures -> stdout/exit)"
	@echo "  make test-plugin-validate L2: manifest surface + privacy (no source) checks"
	@echo "  make test-plugin          L1 + L2 (the default CI gate)"
	@echo ""
	@echo "Needs the runtime bundle (PREDICTABLE_DIST_TOKEN) / API keys:"
	@echo "  make test-plugin-doctor   L4: configuration self-check (scripts/doctor.sh)"
	@echo "  make test-plugin-mcp      L3: 'predictable sync --json' contract on a clone"
	@echo "  make test-plugin-e2e-claude L5: headless claude -p end-to-end run"

lint:
	@shellcheck -x scripts/*.sh tests/*.sh bin/predictable

# L1 — hook-contract tests. Deterministic, no LLM, no runtime bundle. Also runs
# shellcheck internally so `make test-plugin-hooks` alone is a full gate.
test-plugin-hooks:
	@bash tests/run-hooks-test.sh

# L2 — plugin surface + privacy validation. No LLM, no bundle.
test-plugin-validate:
	@bash tests/validate-plugin.sh

# The PR gate: everything that needs neither a key nor the bundle.
test-plugin: test-plugin-validate test-plugin-hooks
	@echo "test-plugin: L1 + L2 passed"

# L4 — configuration self-check. Reports which pieces are present; needs the
# runtime bundle installed (SessionStart bootstrap, PREDICTABLE_DIST_TOKEN).
test-plugin-doctor:
	@bash scripts/doctor.sh

# L3 — 'predictable sync --json' contract against a real clone. Requires the
# runtime bundle. Point PROJECT at a checkout of predictable-code-java-reference.
PROJECT ?= .
test-plugin-mcp:
	@echo "L3: running 'predictable sync --json' in $(PROJECT)"
	@if [ ! -x bin/predictable ]; then echo "bin/predictable not executable"; exit 1; fi
	@cd "$(PROJECT)" && CLAUDE_PLUGIN_ROOT="$(CURDIR)" "$(CURDIR)/bin/predictable" sync --json | jq -e 'keys[0]' >/dev/null \
		&& echo "L3: sync produced a well-formed SyncResponse"

# L5 — headless end-to-end. Requires ANTHROPIC_API_KEY + the runtime bundle.
# Placeholder wiring: the real harness lives with the java-reference test suite.
test-plugin-e2e-claude:
	@if [ -z "$$ANTHROPIC_API_KEY" ]; then echo "test-plugin-e2e-claude: ANTHROPIC_API_KEY required — skipping"; exit 0; fi
	@echo "test-plugin-e2e-claude: drive 'claude -p' against predictable-code-java-reference (see README)."
