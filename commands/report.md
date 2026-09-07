---
description: Open the Predictable Code Control Center (findings + inferred requirements) for this project
---

Open the **Predictable Code** Control Center for this project now — don't ask first.

`predictable serve` starts the local web app that shows the findings and the
requirements inferred per function, and prints its address. It is a SERVER: it
holds the port until stopped, so it must run in the background or it never
returns. It reuses the run that is already listening rather than starting a
second one.

Run this with the Bash tool, `run_in_background: true` (the plugin's gate
auto-approves it, so there is no permission prompt):

```sh
predictable serve --no-open
```

Then post the address it printed — `http://127.0.0.1:7473` unless the port was
taken — as a clickable link. On a remote or headless host the browser open is a
no-op, so the link is the whole answer; `--no-open` keeps it from trying.

Never let this fail the turn. If the server cannot start, say so in one plain
line and carry on: the check's own findings were already reported and the report
is a convenience on top of them.
