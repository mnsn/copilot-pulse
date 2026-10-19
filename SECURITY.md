# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/copilot-pulse/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect. This is a personal
project maintained in spare time, so a reply may take a few days.

## Scope

Copilot Pulse only reads the GitHub Copilot app's files under `~/.copilot` and makes no network
connections. Worth reporting:

- any way it could change or corrupt the Copilot app's data, or keep the app from saving it,
- any way it could expose session contents outside your Mac, and
- problems with how the build scripts here create or sign the app.

Vulnerabilities in the GitHub Copilot app itself should go to GitHub through
[its bug bounty program](https://bounty.github.com).

## Supported versions

Only the latest commit on `main` is supported.
