# Installer and verifier reference

All scripts are in `scripts\`. Run them with Windows PowerShell, using the execution
policy bypass shown in the examples:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\<script>.ps1 [parameters]
```

## Install-BeanCode.ps1

Copies `config\opencode\` into an OpenCode configuration directory.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1 [-Target <dir>] [-DryRun] [-WhatIf] [-BackupExisting] [-InstallNpm]
```

| Parameter | Behavior |
|---|---|
| `-Target <dir>` | Destination directory. Alias: `-Destination`. Default: `%USERPROFILE%\.config\opencode`. |
| `-DryRun` | Prints the plan (`copy`, `skip`, or `conflict` for each file) and exits. Writes nothing and starts no processes. |
| `-WhatIf` | Same effect as `-DryRun`. |
| `-BackupExisting` | Copies each conflicting original to a sibling directory, `<Target>.bak-YYYYMMDD-HHMMSS`, then overwrites it with the payload version. Originals are copied, never deleted or moved. |
| `-InstallNpm` | After copying, runs `npm ci --no-audit --no-fund --registry=https://registry.npmjs.org/` inside `-Target`, using `package-lock.json` from the payload. Optional. The team-bus plugin needs no npm install. |

Examples:

```powershell
# Preview the default installation
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1 -DryRun

# Install into a test directory outside your real configuration
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1 -Target $env:TEMP\beancode-test\opencode

# Install and back up conflicting files first
powershell -ExecutionPolicy Bypass -File .\scripts\Install-BeanCode.ps1 -BackupExisting
```

### Behavior

1. Verifies the payload against `MANIFEST.sha256.json` before anything else. A mismatch stops the run.
2. Refuses unsafe targets: any `..` segment, a drive root, a path inside the repository, a file, or a reparse point (symbolic link or junction).
3. Plans every file before writing. Each file is `copy` (missing), `skip` (identical SHA-256), or `conflict` (differs). A directory or reparse point where a file is expected is refused.
4. Default behavior refuses conflicts. Nothing is written when any conflict exists, unless `-BackupExisting` is given.
5. Copies files byte for byte, then re-hashes each copy against its source.
6. Idempotent: a second run on an identical target reports every file as `skip` and writes nothing.
7. With `-InstallNpm`, refuses to run if `node_modules` already exists in the target, because `npm ci` would delete it. Remove it yourself, then rerun.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or a dry run or `-WhatIf` with a plan |
| 1 | Unexpected error, or a post-copy or backup hash check failed |
| 2 | Payload does not match `MANIFEST.sha256.json`; nothing written |
| 3 | Unsafe target path refused; nothing written |
| 4 | Conflicting files refused (rerun with `-BackupExisting`); nothing written |
| 5 | `-InstallNpm` precondition failed, or `npm ci` failed |

## Verify-BeanCode.ps1

Checks the payload against the manifest and runs the content checks.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1 -Target <dir>
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1 -DenyTermsFile $env:USERPROFILE\my-denyterms.txt
```

| Parameter | Behavior |
|---|---|
| `-PayloadRoot <dir>` | Payload directory. Default: `config\opencode` in the repository. |
| `-ManifestPath <file>` | Manifest file. Default: `MANIFEST.sha256.json` in the repository. |
| `-Target <dir>` | Also verifies an installed copy. Only files listed in the manifest are compared. |
| `-DenyTermsFile <file>` | Opt-in term scan (see below). |

### Always-on checks

- Each manifest entry matches its size and SHA-256 hash. Missing and extra files fail.
- Forbidden names fail: service configuration, backup files, `.env` and auth files, `node_modules`, `.local`, and the `research` folder.
- Reparse points (symbolic links and junctions) fail.
- A generic secret-pattern scan fails on token shapes: GitHub personal and fine-grained tokens, AWS access key IDs, private key blocks, and `sk-` style keys.

### Term scan (opt-in)

Without `-DenyTermsFile`, the term scan is skipped and the output includes a NOTE saying so.

With `-DenyTermsFile <file>`, the verifier searches file names and file contents for the terms in the file:

- The file must be UTF-8, with one term per line. Matching is case-insensitive. Lines starting with `#` are comments, and blank lines are ignored.
- The file must be outside the repository. The verifier refuses a path inside it.
- Keep personal or employer-specific terms only in that file. Do not add them to the repository.
- Output shows the file path and match counts only. It never prints terms or matching lines.
- A hit in `agents\`, `agent\`, `commands\`, `plugins\`, `opencode.jsonc`, `AGENTS.md`, `cli.json`, `btw.jsonc`, or `package*.json` fails. A hit elsewhere is a warning.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-BeanCode.ps1 -DenyTermsFile $env:USERPROFILE\my-denyterms.txt
```

### Output and exit codes

Each run prints a summary line:

```
Manifest entries: N; payload files on disk: N; failures: N; warnings: N; result: PASS|FAIL
```

Failures are printed as `FAIL:` lines, warnings as `WARN:` lines. Exit code `0` means PASS and
`1` means FAIL. Warnings do not change the exit code.

## New-Manifest.ps1

Regenerates `MANIFEST.sha256.json` from `config\opencode\`. It writes UTF-8 without a
byte-order mark and LF line endings. It refuses to manifest any forbidden path.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\New-Manifest.ps1           # write the manifest
powershell -ExecutionPolicy Bypass -File .\scripts\New-Manifest.ps1 -WhatIf   # print the entry count and path; write nothing
```

Run it only after a deliberate payload change, then run `Verify-BeanCode.ps1`.

## BeanCode.Common.ps1

Shared functions dot-sourced by the three scripts: reparse-point checks, SHA-256 hashing,
the payload tree walk, forbidden-path rules, the secret-pattern scan, the optional term scan,
manifest text generation, and the verification routine. It reads file bytes only. It does not
read secrets or state files, start processes, or use the network.
