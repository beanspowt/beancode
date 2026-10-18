# Inventory

`MANIFEST.sha256.json` is the authoritative list. It records `fileCount: 2001`, and it
has 2001 entries. The payload on disk also contains 2001 files.

## Payload (`config\opencode\`)

| Component | Path | Count |
|---|---|---:|
| Skill directories | `skills\<id>\` | 197 |
| Skill files | `skills\**` | 1977 |
| Agents | `agents\*.md` | 11 |
| Legacy agents | `agent\*.md` | 5 |
| Command | `commands\org.md` | 1 |
| Plugin | `plugins\team-bus.js` | 1 |
| Top-level files | `opencode.jsonc`, `cli.json`, `btw.jsonc`, `AGENTS.md`, `package.json`, `package-lock.json` | 6 |
| **Total** | | **2001** |

Both agent directories are kept. The OpenCode 2 migration guide lists `agent/` and `agents/`
as directories V2 still discovers (https://opencode.ai/v2/docs/migrate-v1).

## Agents and models

| Agent | Model (`model:` frontmatter) |
|---|---|
| `agents\auditor.md` | `github-copilot/claude-opus-5.5#high` |
| `agents\director.md` | `github-copilot/gpt-6.1-sol#max` |
| `agents\manager-impl.md` | `github-copilot/claude-sonnet-5.5#high` |
| `agents\manager-quality.md` | `github-copilot/claude-sonnet-5.5#high` |
| `agents\manager-research.md` | `github-copilot/claude-sonnet-5.5#high` |
| `agents\worker-bio.md` | `github-copilot/claude-haiku-5.5#medium` |
| `agents\worker-chem.md` | `github-copilot/claude-haiku-5.5#medium` |
| `agents\worker-coder.md` | `github-copilot/claude-haiku-5.5#medium` |
| `agents\worker-qa.md` | `opencode/deepseek-v4.1-flash-free#high` |
| `agents\worker-research.md` | `opencode/deepseek-v4.1-flash-free#high` |
| `agents\worker-writer.md` | `github-copilot/claude-haiku-5.5#medium` |

Legacy agents in `agent\`: `orchestrator.md`, `research.md`, `responder.md`, `reviewer.md`,
`test-writer.md`. `responder.md` is the generic drafting agent described in
[SANITIZATION.md](SANITIZATION.md).

## Files changed from the source setup

- `opencode.jsonc`
- `AGENTS.md`
- `agents\director.md`
- `agents\manager-research.md`
- `agents\auditor.md`
- `agent\responder.md`

## Not in the repository

Credentials and service configuration, runtime state (history, logs, databases), dependency
folders, backup copies, internal-only agents and internal MCP server entries, and internal
research notes. See [SANITIZATION.md](SANITIZATION.md).

## Repository files outside the payload

| Path | Purpose |
|---|---|
| `README.md`, `docs\*.md` | Documentation |
| `scripts\*.ps1` | Installer, verifier, manifest generator, shared helper ([INSTALLER.md](INSTALLER.md)) |
| `MANIFEST.sha256.json` | Hash manifest for the payload |
| `.gitattributes` | `* -text`: bytes are stored and checked out unchanged |
| `.gitignore` | Ignores secrets, backups, logs, local state, databases, and `node_modules`; keeps the npm lock files tracked |
