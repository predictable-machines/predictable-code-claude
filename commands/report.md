---
description: Open the Predictable Code specs viewer (findings + inferred requirements) for this project
---

Open the **Predictable Code** specs viewer for this project now — don't ask first.

`predictable specs view` regenerates the single self-contained HTML surface (the
findings, plus the inferred requirements per function, every status distinctly
rendered) and opens it in the browser.

Do this in ONE Bash call (the plugin's `PreToolUse` gate auto-approves it, so there
is no permission prompt):

```sh
predictable specs view 2>/dev/null || true
```

It prints a `file://` path — post that clickable link too, since on a remote / SSH /
headless host the browser open silently no-ops. If there are no specs yet, tell the
user to run a check first (say "check specs"); don't fabricate anything.

Keep it to one short line. Never surface engine internals.
