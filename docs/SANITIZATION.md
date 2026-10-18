# Sanitization

This repository contains only the reusable parts of the source setup. This document lists
what was removed, what was edited, and how content is checked.

## Removed

| Category | Reason |
|---|---|
| Credentials and service configuration | Secrets are never committed. |
| Runtime state: session history, logs, databases, locks, caches | Machine-specific. |
| Dependency folders | Reinstalled from `package-lock.json` when needed. |
| Backup copies of configuration files | Would carry stale values. |
| Saved web pages and their sidecar folders | Disposable. |
| Internal research notes | Not part of the setup. |
| Internal-only agents and MCP server entries for internal systems | They depend on proprietary services. |

## Edited

Six files were edited. Each edit removes or generalizes content; no behavior was added.

| File (under `config\opencode\`) | Edit |
|---|---|
| `opencode.jsonc` | Internal MCP server entries removed. The GitHub MCP entry remains, disabled, reading its token from `{env:GITHUB_TOKEN}`. |
| `AGENTS.md` | Internal references removed or generalized. |
| `agents\director.md` | Internal references removed or generalized. |
| `agents\manager-research.md` | Internal references removed or generalized. |
| `agents\auditor.md` | Internal references removed or generalized. |
| `agent\responder.md` | Rewritten as a generic drafting agent. It uses placeholders such as `[YOUR NAME]`, `[YOUR ROLE]`, and `[YOUR ORGANIZATION]`, and it drafts only. |

All other payload files are copied byte for byte.

## Content checks

`scripts\Verify-BeanCode.ps1` runs these checks on every payload file. Full usage is in
[INSTALLER.md](INSTALLER.md#verify-beancodeps1).

- **Structure (always on):** every manifest entry matches its size and SHA-256 hash, no file is missing or extra, forbidden names are absent, and no reparse points are present.
- **Secret patterns (always on):** token shapes are searched for in every text file: GitHub personal and fine-grained tokens, AWS access key IDs, private key blocks, and `sk-` style keys. Any hit fails the check.
- **Term scan (opt-in):** runs only with `-DenyTermsFile <file>`, where the file lives outside the repository and lists the terms you want to exclude. The repository contains no term list. Output shows only the file path and counts.

A passing check reduces the risk of leaks; it does not prove the absence of all sensitive
content. Review changes before committing.
