---
name: install
description: Install or set up Predictable Code (the `predictable` CLI) on this machine, guiding the user through the private-beta approval. Use when the user asks to install, set up, get started with or sign in to Predictable Code, or when a `predictable` command fails because it is not installed ("no predictable on PATH", "command not found").
---

# Predictable Code — install

The full, current steps are at **https://predictablecode.com/install.md** (a
staging or preview Control Center serves its own at `<control-center>/install.md`).
Read that page and follow it. If it cannot be fetched, the steps below are the same.

Rules:

- Ask the user before each command and say what it does.
- Never ask for, read or store a password, a GitHub token or any secret: the user
  approves a GitHub sign-in in their own browser.
- Never pipe a download into a shell; the command below downloads to a file first.
- Predictable Code is in private beta. If the user is not admitted, give them the
  Request access link the installer prints and stop. Never look for the software
  anywhere else.

## 1. Check

`predictable --version` already printing a version means it is installed: skip to 4.
It runs on macOS on Apple Silicon and Linux x86_64 (WSL on Windows); check `uname -sm`.

## 2. Run the installer

```sh
curl -fsSL https://predictablecode.com/install.sh -o predictable-install.sh && bash predictable-install.sh
```

Run it in the background (or with `PREDICTABLE_INSTALL_SIGN_IN_WAIT=60` in front of
`bash`, so one run waits at most a minute) and read its output. It first prints a
GitHub address and a code:

```
  Open:            https://github.com/login/device
  and enter code:  ABCD-1234
```

Show the user both exactly as printed and ask them to approve in their browser.

## 3. Its exit status

| Status | Meaning | Do |
| --- | --- | --- |
| 0 | Installed, and this machine is signed in. | Continue to 4. |
| 75 | Not approved yet. | Run the SAME command again: it waits on the same code. |
| 77 | The user's GitHub account is not in the beta. | Show the Request access link it printed (sign in with GitHub, then a short form; they are told by email once admitted), then stop. |
| 1 | Anything else; the output says why. | Read it to the user. An expired or cancelled code: run it again for a new one. |

## 4. Use it here

Claude Code must see the new `predictable`: the installer put `~/.local/bin` on the
PATH in the shell profile, so the user restarts Claude Code from a new shell. Then
`predictable whoami` names their GitHub account, and the `sync` skill
(`/predictable-code:sync`) checks this repository. To analyse on GitHub too, the user
opens their Control Center, installs the Predictable Code GitHub App and presses
**Turn on analysis** on the repository.
