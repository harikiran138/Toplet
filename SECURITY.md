# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private vulnerability
reporting instead: on the repository page, open **Security → Report a vulnerability**.

Include what you found, how to reproduce it, and the macOS and Toplet versions. We aim to
acknowledge a report within 3 days and to agree on a fix and disclosure date with you.

## What is in scope

Toplet runs locally and talks to other software on your Mac, so these areas matter most:

- The agent socket in `~/.atoll/run/` and the hooks Toplet installs into Claude Code and Codex
- The extension XPC and WebSocket interfaces
- Credentials Toplet reads or stores (Keychain items, local token files of other apps)
- AppleScript and shell commands built from user or app data
- Anything that sends data off the Mac

## Supported versions

Fixes go into the latest release and the `main` branch.
