---
description: Open the Predictable Code Control Center (findings + inferred requirements) for this project
---

Open the **Predictable Code** Control Center for this project now — don't ask first.

The Control Center is hosted: it shows the findings and the requirements inferred
per function for every analysis this machine published. Get this project's link
with the Bash tool (the plugin's gate auto-approves it, so there is no permission
prompt):

```sh
"${CLAUDE_PLUGIN_ROOT}/scripts/control-center-url.sh"
```

It prints one line. When it exits 0 the line is the link: post it as a clickable
link. When it exits 1 the line says why there is no link (the machine is not
signed in, or the checkout has no GitHub `origin`): say that in one plain line.

Never let this fail the turn: the check's own findings were already reported, and
the Control Center is a convenience on top of them.
