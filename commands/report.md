---
description: Open the Predictable Code HTML report (findings + inferred requirements) for this project
---

Open the **Predictable Code** report for this project now — don't ask first.

Every check writes a self-contained HTML report (the findings, plus the inferred
requirements per function) to `.predictable-code/inference/report.html`.

Do this:

1. If `.predictable-code/inference/report.html` does **not** exist, tell the user
   there is no report yet and to run a check first (say "check specs") — do NOT try
   to generate one here, and stop.
2. Otherwise open it with the OS default handler in ONE Bash call (the plugin's
   `PreToolUse` gate auto-approves this exact command, so there is no permission
   prompt):

   ```sh
   open .predictable-code/inference/report.html 2>/dev/null || xdg-open .predictable-code/inference/report.html 2>/dev/null || true
   ```

3. Also post the clickable absolute **`file://`** link — on a remote / SSH /
   headless host `open` silently no-ops, so the link is the fallback.

Keep it to one short line (the report opened, or there isn't one yet). Never
surface engine internals.
