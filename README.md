# beancode

beancode is a sanitized, reproducible copy of a personal OpenCode 2.x setup: agents,
skills, one command, one plugin, and configuration. It is a restore kit for a personal
Windows PC. Clone it, verify it against its manifest, dry-run the installer, then
install it into your OpenCode configuration directory.

The repository is private and owned by the GitHub account `beanspowt`. Cloning requires
GitHub authentication with read access (see [Prerequisites](#prerequisites)).

| Document | Contents |
|---|---|
| [docs/INSTALLER.md](docs/INSTALLER.md) | Installer and verifier parameters, behavior, and exit codes |
| [docs/INVENTORY.md](docs/INVENTORY.md) | Payload contents and counts |
| [docs/SANITIZATION.md](docs/SANITIZATION.md) | What was removed or changed, and the content checks |

## Layout

```
beancode\
├─ README.md
├─ MANIFEST.sha256.json            SHA-256 hash and size of every payload file
├─ .gitattributes                  "* -text": bytes are stored and checked out unchanged
├─ .gitignore
├─ config\opencode\                payload, copied to the OpenCode config directory
│  ├─ skills\                      skill directories, each with SKILL.md
│  ├─ agents\                      agent definitions (*.md)
│  ├─ agent\                       legacy agent definitions (*.md)
│  ├─ commands\org.md              custom command
│  ├─ plugins\team-bus.js          plugin (Node.js built-in modules only)
│  ├─ opencode.jsonc               main OpenCode configuration
│  ├─ cli.json                     terminal client configuration
│  ├─ btw.jsonc                    additional configuration
│  ├─ AGENTS.md                    global instructions
│  ├─ package.json
│  └─ package-lock.json            lock file used by the optional -InstallNpm step
├─ scripts\
│  ├─ Install-BeanCode.ps1         installs the payload
│  ├─ Verify-BeanCode.ps1          verifies the payload (and optionally an installed copy)
│  ├─ New-Manifest.ps1             regenerates MANIFEST.sha256.json
│  └─ BeanCode.Common.ps1          shared helper, dot-sourced by the three scripts
└─ docs\
```

Payload totals are in [docs/INVENTORY.md](docs/INVENTORY.md). The manifest is the
authoritative file list.

## Prerequisites

| Requirement | Needed for |
|---|---|
| Windows PowerShell 5.1 or PowerShell 7 | Running the scripts |
| Git for Windows | Cloning |
| GitHub CLI (`gh`) | Authenticating to the private repository |
| OpenCode 2.0.32 | The tool this payload configures. You install it yourself; the installer never does. |
| Node.js and npm | Optional `-InstallNpm` step only |
| `officecli` (external binary) | The `officecli` skill for Word, Excel, and PowerPoint files |
| Python and per-skill dependencies | Skills that run scripts; install them as each skill's documentation describes |

### Installing OpenCode 2.0.32

Official V2 install options (https://opencode.ai/v2/docs/):

- Windows x64 zip: `https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-x64.zip`
  (also published: `opencode-windows-x64-baseline.zip` and the ARM64 zip, same location)
- npm, any platform: `npm install -g @opencode/cli`

The V2 page states: "Windows package managers are not supported." Install with one of
the two methods above.

OpenCode 1 and OpenCode 2 both use the `opencode` command. They are not installed side by
side by default, so remove any package-managed V1 installation first, as the migration
guide describes (https://opencode.ai/v2/docs/migrate-v1).

To pin the version, install that version of the npm package
(`npm install -g @opencode/cli@2.0.32`). Confirm the installed version with
`opencode --version`.

## Restore on Windows

Run these commands in PowerShell.

1. Authenticate GitHub CLI, once per machine:

   ```powershell
   gh auth login
   ```

2. Clone the repository:

   ```powershell
   git clone https://github.com/beanspowt/beancode.git
   cd .\beancode
   ```

3. Verify the payload against the manifest:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1
   ```

4. Preview the installation. Nothing is written:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1 -DryRun
   ```

5. Install into the default target, `%USERPROFILE%\.config\opencode`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1
   ```

   For isolated testing, pass another directory with `-Target <dir>`. Full parameters,
   conflict handling, and exit codes are in [docs/INSTALLER.md](docs/INSTALLER.md).

6. Start OpenCode and connect a provider (see [Authentication](#authentication)).

## Authentication

Three separate credentials are involved. Each one is independent of the others.

### 1. GitHub CLI (repository access)

`gh auth login` lets Git clone the private repository. It gives OpenCode no model access.

### 2. OpenCode provider login (models)

Official V2 documentation (https://opencode.ai/v2/docs/cli/providers):

- In the terminal interface, run `/connect`, choose a provider, then run `/models`.
- From a shell, run `opencode auth login` for a provider picker, or
  `opencode auth login <provider>`. Run `opencode auth list` to see saved accounts.
- Credentials are stored in OpenCode's database. Manage them with `/connect` or the
  `auth` commands; do not edit the database.

The agent files set models in their `model:` frontmatter, using the form
`provider/model#variant`, for example `github-copilot/claude-haiku-5.5#medium`. Model
access depends on your own subscriptions and entitlements. If a model is unavailable to
your account, change that agent's `model:` line (or remove it, so the agent uses the
session default), or override the model under `agents` in `opencode.jsonc`. The list of
models in use is in [docs/INVENTORY.md](docs/INVENTORY.md).

### 3. Optional GitHub MCP server (GitHub API tools)

The GitHub MCP server in `opencode.jsonc` is disabled by default with `"disabled": true`.
V2 uses `disabled` to keep a server configured but not connected; it does not use
`enabled: false` (https://opencode.ai/v2/docs/mcp-servers).

To enable it:

1. Create a personal access token on your own GitHub account.
2. Store the token as a user environment variable named `GITHUB_TOKEN`, for example
   `setx GITHUB_TOKEN "<token>"`. Open a new terminal afterwards.
3. In `opencode.jsonc`, set the server's `disabled` to `false`, or remove that line.

The configuration reads the token with `{env:GITHUB_TOKEN}`, so the token is never stored
in the repository. Do not commit tokens.

## Plugin state

`plugins\team-bus.js` imports only Node.js built-in modules. It keeps its runtime state in
`%USERPROFILE%\.local\share\opencode-team`, or in the directory named by the `TEAM_BUS_DIR`
environment variable if that is set. The plugin creates the directory when it first runs.
That state is not part of this repository and is never installed or verified by these
scripts.

## Safe defaults

- The GitHub MCP server stays disabled until you add your own token.
- The installer refuses to overwrite files that differ from the payload unless you pass `-BackupExisting`.
- `-BackupExisting` copies originals; it never deletes anything.
- The installer verifies the payload before writing and refuses unsafe target paths.
- The repository contains no credentials, service configuration, or runtime state.

## Verification

`scripts\Verify-BeanCode.ps1` always runs these checks:

- Every manifest entry matches its size and SHA-256 hash; no file is missing or extra.
- Forbidden names are absent: service configuration, backup files, environment and auth files, `node_modules`, `.local`, and the `research` folder.
- No reparse points (symbolic links or junctions) are present.
- A generic secret-pattern scan finds no token shapes (GitHub tokens, AWS access keys, `sk-` style keys, private key blocks).

The personal and employer-specific term scan is opt-in. It runs only when you supply a
term file that lives outside this repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1 -DenyTermsFile $env:USERPROFILE\my-denyterms.txt
```

The file is UTF-8 with one case-insensitive term per line; lines starting with `#` are
comments. The output reports only the file path and match counts; it never prints terms or
matching lines. Keep your terms out of the repository. Without `-DenyTermsFile`, the output
includes a NOTE that the term scan was skipped. Details are in
[docs/INSTALLER.md](docs/INSTALLER.md#verify-beancodeps1).

## What is and is not tested

**Tested locally (file level):**

- `Verify-BeanCode.ps1` checks all 2001 manifest entries against the payload: result PASS, 0 failures, 0 warnings. With and without a term file.
- The static secret-pattern scan passes on the payload.
- The term scan runs only when a term file is supplied.
- `Install-BeanCode.ps1` was run against an empty temporary target: `-DryRun` planned 2001 copies, writing nothing; the real install wrote 2001 files; `Verify-BeanCode.ps1 -Target` on that copy returned PASS.
- A second install was idempotent (2001 files already identical).
- A modified file caused exit code 4 without `-BackupExisting`. With `-BackupExisting`, the original was copied to a sibling `<Target>.bak-<timestamp>` directory, and the target file was replaced with the payload version.
- Target paths containing `..` returned exit code 3. A target inside the repository returned exit code 3. `-WhatIf` wrote nothing.
- A scripted installer test suite ran in a temporary folder against synthetic fixtures. It is not shipped in this repository.

**Not tested in this repository:**

- `-InstallNpm` (the `npm ci` step; it contacts the public npm registry).
- Live OpenCode runtime behavior: model responses, agent delegation, skill loading, command execution, and the plugin inside a running OpenCode.
- MCP connections, including the GitHub MCP server with a token.
- Model entitlements for any model named in the agents.

**Optional check on your own machine after installation:**

```powershell
opencode debug agents
```

Expect the 16 custom agents (11 in `agents\`, 5 in `agent\`) listed with the engine's built-in agents.
Skills are listed by the same kind of check: expect 197 custom skills alongside the built-in
skills.

## Layout compatibility

OpenCode 2.0.32 discovers several directory names for the same content. The official V2 migration guide states that V2 still discovers `agent/` and `agents/`, `mode/` and `modes/`, `command/` and `commands/`, `skill/` and `skills/`, and `plugin/` and `plugins/`, and that it translates legacy agent frontmatter automatically (https://opencode.ai/v2/docs/migrate-v1). This payload keeps `agents\` (11 files) and `agent\` (5 files) as they are; they are not merged.

## Sanitization

Removed from the source setup: credentials and service configuration, runtime state (history, logs, databases, locks, caches), dependency folders, backup copies, internal-only agents and MCP server entries for internal systems, and internal research notes. Six files were edited: `opencode.jsonc`, `AGENTS.md`, `agents\director.md`, `agents\manager-research.md`, `agents\auditor.md`, and `agent\responder.md`. The responder is a generic drafting agent with placeholders such as `[YOUR NAME]`. Full details are in [docs/SANITIZATION.md](docs/SANITIZATION.md).

## Licensing

This repository has no top-level `LICENSE` file. The configuration you own is provided as-is. Bundled third-party skills keep their own notices and licenses in their folders; look for `LICENSE*` or `NOTICE*` files there.

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `git clone` fails with an authentication or 404 error | The repository is private. Run `gh auth login` with an account that has read access, then retry. |
| `opencode --version` shows a version other than 2.0.32 | A V1 installation is on PATH. Remove it, then install V2 by one of the documented methods. |
| `Verify-BeanCode.ps1` reports `FAIL` | The working copy has changed. Restore it with `git checkout -- .`, then verify again. Do not regenerate the manifest to hide a mismatch. |
| The installer exits with code 4 | Target files differ from the payload. Rerun with `-BackupExisting`, or use `-Target` for a test directory. |
| The installer exits with code 5 | The `-InstallNpm` precondition failed, or `npm ci` failed. See [docs/INSTALLER.md](docs/INSTALLER.md). |
| A model is unavailable | Your account lacks that model. Edit the agent's `model:` line or override it in `opencode.jsonc`. |
| The GitHub MCP server does not connect | It is disabled by default. Set `GITHUB_TOKEN` and set `disabled` to `false`, then open a new terminal. |
| The `officecli` skill fails | Install the external `officecli` binary and make sure it is on PATH. |
| A skill is not offered to the model | Check that the skill folder has `SKILL.md` with a `description`, and that the agent's `skill` permissions allow it. |
